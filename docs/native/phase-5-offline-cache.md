# 第五阶段 · 离线缓存能力审计与边界（phase-5-offline-cache）

> 任务：**T-P1-13**（断网歌单播放）的**交付 A**：缓存能力审计 + 边界确认 + 测试缺口补齐
> 关联文档：`docs/native/phase-5-offline-playlist.md`（行为交付：R-1 ~ R-4、Store 接线、决策登记）
> 关联矩阵项：F-DL-004、F-CACHE-009、F-NET-007/009
>
> **文档命名差异登记**：本阶段开始前仓库已有 `phase-5-offline-playlist.md`（T-P1-13 行为交付，提交 `908d349`）。
> 任务书要求的 `phase-5-offline-cache.md` 在本文件落地，定位为**缓存能力审计与边界**（A1/A2/A3/A4），
> 与行为交付文档**互补而非重复**：行为文档回答「断网时播放怎么走」，本文件回答「缓存到底是什么、边界在哪」。

---

## 1. A1：任务真实语义确认（逐问作答，均为源码核实）

| # | 问题 | 答案 | 证据 |
|---|---|---|---|
| 1 | 断网时歌单是否仅要求可查看，还是已缓存音频可继续播放？ | **要求已缓存音频可继续播放**（不只是可查看） | 产品需求原文：「若存在可播放的缓存歌曲则继续播放」 |
| 2 | 现有缓存究竟缓存什么？ | **音频字节**（Media3 `SimpleCache` 落盘的数据段）+ **源记忆**（`songId\|quality → 上次解析到的 URL`，存 SharedPreferences）。**不**缓存 HTTP 响应对象、**不**缓存歌曲元数据到独立表、封面缓存归 Coil（与播放缓存无关） | `player/offline/PlaybackCacheStore.kt`、`player/offline/ResolvedSourceMemory.kt` |
| 3 | 是否用 Media3 Cache / SimpleCache / CacheDataSource？ | **是**：`SimpleCache` + `CacheDataSource`（经 `DefaultMediaSourceFactory` 接入 ExoPlayer） | `PlaybackCacheStore.dataSourceFactory`；`AudioEngineConfig.dataSourceFactory` |
| 4 | 容量、淘汰、键、生命周期？ | 容量 **512 MiB**（常量，待 F-CACHE-009 接线）；淘汰 **LRU**（`LeastRecentlyUsedCacheEvictor`）；键 **`songId\|quality`**（`PlaybackCacheKeys.key`，与易变签名 URL 解耦）；生命周期 = 应用私有 `cacheDir` 子目录，`SimpleCache` **进程内单例**（同目录多实例会抛异常） | 同上；`PlaybackCacheKeys.kt` |
| 5 | 断网时播放**当前已缓存**曲目是否可行？ | **可行**：`CacheDataSource` 先查缓存，命中则完全不走网络；引擎的 `DataSource` 上游失败被 `FLAG_IGNORE_CACHE_ON_ERROR` 之外的路径正常处理 | `PlaybackCacheStore` 的 `CacheDataSource.Factory` 配置 |
| 6 | 下一首未缓存时，队列应停留 / 报错 / 按契约跳过？ | **按契约前进到下一首已缓存曲**；若无任何可播缓存 → **停止（保留队列 + 错误态）** | `OfflineAdvancePolicy` + `PlaybackIntent.OfflineNoPlayableCache`；行为细节见 `phase-5-offline-playlist.md` |
| 7 | 音源 URL 过期 / 需鉴权 / 无法重新解析时如何处理？ | **键与 URL 解耦**，故 URL 过期**不影响缓存命中**；但**恢复/重建播放项**需要「上次解析到的源」（`ResolvedSourceMemory`）。若该源也已失效（CDN 拒绝），播放失败 → 走既有错误/恢复链（离线时不消耗预算、不排期退避） | `PlaybackCacheKeys` KDoc；`PlaybackCacheStore.resolvedSource` |
| 8 | 当前是否存在任何独立下载 / 离线曲库 / 持久化下载记录？ | **不存在**。全仓无下载任务队列、无离线曲库表、无断点下载、无下载管理页、无独立离线歌曲文件管理 | `grep -rn "DownloadManager\|downloadQueue\|offlineLibrary" native/app/src/main` 为空 |

> **结论**：T-P1-13 的真实范围 = **「播放缓存 + 源记忆 + 离线前进策略」**，**不是**离线下载系统。与产品约束 5/6（只做播放缓存、不做离线下载）**一致，无冲突**。

---

## 2. A2：可实现边界（已实现 vs 明确不做）

**已实现（符合约束的最小充分集）**

| 边界 | 实现 |
|---|---|
| 已加载歌单与必要元数据可展示 | `PlaybackState.queue`（内存）+ `PlaybackQueueCodec`（持久化，T-P1-10） |
| 已有合法、完整、可读的缓存时从缓存继续播放 | `CacheDataSource`（命中即不走网络） |
| 断网且缓存不可用时返回明确、可观测的错误状态 | `PlaybackIntent.OfflineNoPlayableCache` → `resolveError` + UI 可展示文案 |
| 缓存未命中时**不**自动下载整首 / 不生成离线副本 | 无下载代码路径（A1-8） |
| 网络恢复后允许按既有解析链路重新解析 | `RetryCurrent` 走既有 `ResolveSongUrl`（离线门只拦「前进」路径） |
| 缓存失效 / 源过期时不把过期结果永久视为有效 | 键与 URL 解耦 + `ResolvedSourceMemory` 可覆盖；失效源播放失败走既有错误链 |
| 不允许未经授权的缓存访问 / 不绕过服务端访问控制 | 缓存只存**已成功获取**的字节；`/audio/proxy` 403 不绕过（既有实现未改动） |

**明确不做（登记）**

- 离线下载 / 下载队列 / 离线曲库 / 断点下载 / 下载管理页；
- 预下载整专辑 / 智能缓存策略（F-CACHE-009 只做「缓存大小设置」，不做预取）；
- 缓存内容的加密（`SimpleCache` 落盘明文；源记忆在应用私有 prefs，未加密——见 R5-23）。

---

## 3. A3：缓存实现审计（逐条核验）

| 审计项 | 结论 | 证据 |
|---|---|---|
| 是否已有 Media3 缓存工厂 | ✅ `PlaybackCacheStore.dataSourceFactory`（委托工厂，延迟构造） | `PlaybackCacheStore.kt` |
| 缓存是否只被播放数据源使用 | ✅ 唯一消费点是 `AudioEngineConfig.dataSourceFactory` → 主引擎 | `di/PlayerModule.provideMainAudioEngine` |
| 缓存键是否稳定、不会混淆不同资源 | ✅ 键 = `songId\|quality`，**与 URL 解耦**；不同音质档是不同资源 → 不同键 | `PlaybackCacheKeys`；测试 `缓存键_不同音质档互不命中` |
| 缓存元数据是否含敏感信息 | ✅ 不含：`PersistedSong` 无 `url`；源记忆虽存 URL，但只在应用私有 prefs，且**禁止写日志**（KDoc 硬约束） | `PlaybackQueueCodec.kt`、`ResolvedSourceMemory.kt` |
| 是否存在无限增长 / 缺淘汰 / 文件句柄泄漏 | ✅ 有上限（512 MiB）+ LRU 淘汰；`SimpleCache` 进程内单例（`by lazy` SYNCHRONIZED） | `PlaybackCacheStore.cache` |
| 断网时网络请求是否能快速失败而非长时间阻塞 | ✅ 命中缓存时**不发网络请求**；未命中时由 OkHttp 超时（既有配置）+ `CacheDataSource` 的上游失败路径处理 | 既有网络层配置 |
| 缓存命中是否确实读本地而非重新访问网络 | ✅ 端到端测试用真 `CacheDataSource` + `file://` 上游验证；另有「完整读完后判定成立」用例 | `PlaybackCacheStoreTest` 的端到端用例 |
| 容量与淘汰策略是否已有产品约定 | ⚠️ **暂无**（512 MiB 为临时常量，登记待 F-CACHE-009 接线读设置） | `PlaybackCacheConfig.maxBytes` |

**审计结论**：缓存实现**已满足** T-P1-13 所需的最小能力，**无需新增**缓存设施。本阶段只做**测试缺口补齐**（A4）。

---

## 4. A4：测试覆盖（12 类要求的逐条对照）

| # | 要求 | 覆盖 | 位置 |
|---|---|---|---|
| 1 | 网络可用且缓存未命中 | ✅ | `SimplePlaybackCacheResolverTest.未缓存时返回 null` |
| 2 | 网络可用且缓存命中 | ✅ | `SimplePlaybackCacheResolverTest.已完整缓存且记住源时返回该源` |
| 3 | 断网且缓存可用 | ✅ | `OfflineAdvanceStoreTest.R1_R2_*` |
| 4 | 断网且缓存未命中 | ✅ | `OfflineAdvanceStoreTest.R3_离线候选全未缓存_停止播放_*` |
| 5 | 缓存部分命中（hole） | ✅ | `PlaybackCacheStoreTest.部分缓存_hole_不算已完整缓存` |
| 6 | 缓存被淘汰或失效 | ✅ | `PlaybackCacheStoreTest.LRU 淘汰后判定翻转` |
| 7 | **音源 URL 过期** | ✅ **本阶段补齐** | `OfflineCacheBoundaryTest.音源过期_*`（3 条） |
| 8 | **网络恢复后的重新解析** | ✅ **本阶段补齐** | `OfflineCacheBoundaryTest.网络恢复后_用户手动重试触发重新解析` |
| 9 | **当前歌曲已缓存但下一首未缓存** | ✅ **本阶段补齐** | `OfflineCacheBoundaryTest.当前曲已缓存但后续全未缓存_停止且不回退重播当前曲` |
| 10 | **缓存读取失败和文件损坏** | ✅ **本阶段补齐** | `OfflineCacheBoundaryTest.缓存文件被外部清理_判定为未缓存且不抛异常`；`PlaybackCursorStoreTest.损坏 JSON 返回 null 不抛异常` |
| 11 | **缓存容量上限及淘汰** | ✅ **本阶段补齐** | `OfflineCacheBoundaryTest.容量上限_*`（3 条） |
| 12 | 断网不会触发无界重试 / 无限等待 / 下载行为 | ✅ | `AudioFocusStoreTest.系统中断暂停_不触发任何重试动作_即使推进退避窗口`；`OfflineAdvanceStoreTest.R3_*不派发重试`；无下载代码路径（A1-8） |

**本阶段新增测试（11 条）**：`player/offline/OfflineCacheBoundaryTest.kt`

测试用**真 `SimpleCache`**（Robolectric + 临时目录）+ 最小 fake 引擎，**不依赖真实付费音源 / 真实凭据 / 外部资源**。

---

## 5. 遗留风险

| ID | 描述 | 严重度 | 归属 |
|---|---|---|---|
| R5-01 | 缓存上限为常量 512 MiB，未读用户设置 | 🟡 | **F-CACHE-009** |
| R5-02 | `SimpleCache` 用 legacy 文件索引（未接 `StandaloneDatabaseProvider`），大缓存下索引加载可能偏慢 | 🟡 | 后续 |
| R5-03 | 源记忆未加密（`MODE_PRIVATE` = 应用隔离，非静态加密） | 🟢 | 后续 |
| R5-04 | 缓存命中率**未实测**（真机断网场景） | 🔴 | 用户实测 |
| R5-05 | `Previous` 方向不做缓存过滤（只做「前进」方向，产品确认） | 🟢 | 待确认 |
| R5-06 | 缓存降级档位语义：「键代表请求档、字节可能是降级档」（引擎按 `Song.quality` 写键） | 🟢 | 已登记 |
| R5-07 | 真机断网切歌 / 弱网恢复 / Android 7–9 兼容**未执行** | 🔴 | 用户实测 |
