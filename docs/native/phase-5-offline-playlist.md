# 第五阶段 · 离线歌单播放行为（phase-5-offline-playlist）

> 状态：**代码层已交付**（生产实现 + Hilt 接线 + 单测 + 文档）；**真机未验证**。
> 触发：2026-10-15 产品需求（见 §1）。
> 关联：`docs/native/phase-4-recovery.md`（恢复执行器）、`docs/native/phase-4-risks.md`（R4-02 / R4-04）、
> 工作区 `docs/implementation-roadmap.md` §T-P1-13、`docs/feature-migration-matrix.md` §5.34（F-DL-004）。
>
> ⚠️ 本文档只声明**已实际实现并由单测覆盖**的能力。§10 明确列出未完成项与未验证项；
> 真机行为（断网切歌、缓存命中率、Android 7–9 兼容）**一律不得**据本文宣称可用。

---

## 1. 需求原文（2026-10-15，逐字保留）

> 断网情况下，在线歌单播放时的行为需调整：当当前歌单歌曲下方歌曲未缓存、循环到歌单下一首已缓存歌曲，
> 若存在可播放的缓存歌曲则继续播放，若无任何可播放歌曲则停止播放，
> 并且网络恢复后不自动恢复播放，需等待用户手动操作。

## 2. 可验收断言（R-1 ~ R-4）

| # | 断言 | 触发时机 | 覆盖测试 |
|---|---|---|---|
| **R-1** | 断网 + 播放在线歌单时，若「当前曲之后」的曲目未缓存，则**绕到歌单中下一首已缓存曲目** | 需要推进到下一首时（自然播完 / 失败跳歌 / 用户点下一首） | `OfflineAdvancePolicyTest`、`OfflineAdvanceStoreTest` |
| **R-2** | 若歌单中存在**可播放的缓存曲目**，则继续播放该曲 | 同上 | 同上 |
| **R-3** | 若歌单中**不存在任何可播放的缓存曲目**，则**停止播放** | 同上 | `OfflineAdvanceStoreTest`、`PlaybackReducerTest`（`OfflineNoPlayableCache`） |
| **R-4** | 网络恢复后**不自动恢复播放**，须等用户手动操作 | 连接状态由离线 → 在线 | `OfflineAdvanceStoreTest`、`RecoveryOrchestratorTest` |

「循环到」按歌单循环语义理解：从当前索引出发向后枚举候选，到队尾后按当前 `AppLoopMode` 决定是否绕回队首
（**不**按「只找当前索引之后」的字面理解——否则队尾之后无可播缓存曲时会与 R-3 冲突）。

## 3. 落地前现状审计（事实，均为源码核实）

| 能力 | 落地前 native 现状 | 证据 |
|---|---|---|
| 音频播放缓存层 | **不存在** | 无 `CacheDataSource` / `SimpleCache` 使用；适配器只做纯字符串路径构造 |
| 缓存命中查询 | **不存在** | 无 `resolveLocalAudioPath` 等价物 |
| 网络可用性探测 | **不存在（硬编码 `true`）** | `PlaybackStore.StoreEngineListener.isNetworkAvailable()` 曾恒 `true`；`RecoveryOrchestrator` KDoc 自述 `NETWORK_UNAVAILABLE` 分支不可达（风险 R4-02） |
| 离线差异化处理 | **不存在** | `classifyPlaybackRecoveryFailure(networkAvailable = true)` → 永远走 `TRANSIENT_RESOLUTION` |
| 失败后自动重试 | 已实现且默认开启 | `RecoveryOrchestrator.scheduleBackoff()`（失败即排期 30/60/120s） |
| 网络恢复后自动重试 | 已实现（`onExternalRecoveryTrigger()`），由 `PlaybackEvent.NetworkChanged` 驱动 | `PlaybackStore.dispatch(event)` 曾含该连线 |
| 解析失败自动跳歌 | 已实现 | `RecoveryOrchestrator.maybeAutoSkip()`，上限 `playlistSize - 1` |
| 前后台信号 | **无生产者** | `AppForegroundChanged` 在归约层为 no-op（R4-01） |

### 3.1 与既有实现的冲突点（落地时已处理）

1. **R-4 与自动重试策略冲突** → 采用「离线失败不消耗预算、不排期退避」+「`NetworkChanged` 不再驱动
   `onExternalRecoveryTrigger()`」。见 §4.5。
2. **R-1/R-3 与 `maybeAutoSkip()` 判据冲突** → 离线路径把跳歌候选**过滤为已缓存曲目**，
   候选为空时**停止**而非继续跳。见 §4.4 / §5.1。
3. **R-3「停止播放」的状态表达** → 决策为「`Pause` + 保留队列 + `resolveError` 错误态」，
   **不**走 `PlaybackIntent.Stop`（那会作废请求并清播放态）。见 §4.6 / §6 Q2。

## 4. 交付内容

### 4.1 缓存层（S1）

| 文件 | 职责 |
|---|---|
| `N/…/player/offline/PlaybackCacheStore.kt` | Media3 `SimpleCache` + `CacheDataSource` 的唯一持有者；`isFullyCached(key)`（`exo_len` 长度基准 + span 连续覆盖判定）、`resolvedSource` / `rememberResolvedSource`；`dataSourceFactory` 为**委托工厂**（`SimpleCache` 构造推迟到加载线程的 `createDataSource()`，主线程零磁盘 I/O） |
| `N/…/player/offline/PlaybackCacheKeys.kt` | 缓存键唯一构造入口 `key(songId, quality) = "songId\|quality"`；键与**易变签名 URL 解耦**（否则缓存永不命中） |
| `N/…/player/offline/PlaybackCacheResolver.kt` | 查询端口（冻结契约）：`suspend resolveCachedSource(songId, quality): String?` + `rememberResolvedSource(...)`；含 `NoOpPlaybackCacheResolver` 降级实现 |
| `N/…/player/offline/SimplePlaybackCacheResolver.kt` | 生产实现，委托 `PlaybackCacheStore`；两个方法都切 `Dispatchers.IO`（可注入），`withContext` 天然可取消 |
| `N/…/player/offline/ResolvedSourceMemory.kt` | 「`songId\|quality` → 上次解析到的源」的持久化端口 + `SharedPreferencesResolvedSourceMemory`（`MODE_PRIVATE`，`apply()` 异步落盘） |

接入点：`AudioEngineConfig.dataSourceFactory: DataSource.Factory?`（**默认 `null` = 与改造前逐字节一致**）
→ `AudioEngineFactory` 经 `DefaultMediaSourceFactory` 挂到 `ExoPlayer.Builder.setMediaSourceFactory`；
`PlayerModule.provideMainAudioEngine` 注入 `PlaybackCacheStore.dataSourceFactory`。
引擎写入键：`ExoPlayerPlaybackEngineAdapter.prepare` 的 `MediaItem.setCustomCacheKey(PlaybackCacheKeys.key(...))`。

**缓存上限**：`PlaybackCacheStore.DEFAULT_MAX_CACHE_BYTES = 512 MiB` + `LeastRecentlyUsedCacheEvictor`
（**临时决策**：待 F-CACHE-009「缓存大小设置」接线后改为读用户设置）。
**缓存索引**：用 `SimpleCache(File, CacheEvictor)` 2 参 legacy 索引（不引入 `media3-database`）；
官方标注该构造在大缓存下性能较差，登记为后续收敛项。
**新增依赖**：`libs.media3.datasource`（`androidx.media3:media3-datasource`，版本与 `media3` 同 ref）
——`:media3fork` 以 `implementation` 声明故编译期不外泄，需 `:app` 显式声明；无新增第三方依赖。

### 4.2 网络可用性（S2）

| 文件 | 职责 |
|---|---|
| `N/…/player/offline/NetworkAvailabilityProvider.kt` | `fun interface`：`isNetworkAvailable(): Boolean`；含 `AlwaysOnlineNetworkAvailabilityProvider`（默认/测试） |
| `N/…/player/offline/AndroidNetworkAvailabilityProvider.kt` | `ConnectivityManager` **同步按需查询**（非 `NetworkCallback`，避免注册/注销生命周期与泄漏面）；判定：无活动网络 → `false`；有 `NET_CAPABILITY_INTERNET` → `true`；无法判定/任何异常 → 保守 `true` |

`PlayerModule.provideNetworkAvailabilityProvider` 绑定生产实现后，`PlaybackStore.StoreEngineListener`
的 `isNetworkAvailable()` 返回真实值 → `RecoveryOrchestrator` 的 `NETWORK_UNAVAILABLE` 分类分支**变可达**，
风险 **R4-02 关闭**。
权限：`ACCESS_NETWORK_STATE` 已在 `native/app/src/main/AndroidManifest.xml:6` 声明（本阶段未改 Manifest）。

**偏离登记**：任务提示「有条件时用 `NET_CAPABILITY_VALIDATED` 更准确」，本实现**不要求** VALIDATED
（它由系统连通性探测异步置位，刚连上 Wi-Fi 的数百毫秒内通常尚未置位；若要求它会误判「离线」并触发
R-3 停播）。取向是「宁可『有网但解析失败』（走既有失败恢复链），不可『明明有网却主动停播』」。

### 4.3 纯策略（S3）

`N/…/player/offline/OfflineAdvancePolicy.kt`：`choose(candidates: List<Int>, cachedOf: (Int) -> Boolean)`
→ `Decision.Play(index)` / `Decision.Stop`。**零 I/O、零协程、零 Android 依赖**，可纯单测、可重放；
负下标一律不进入谓词；首个命中即短路返回。

### 4.4 Store 接线（S4）

`N/…/player/store/PlaybackStore.kt`：

- 构造器新增 `cacheResolver: PlaybackCacheResolver`、`networkAvailability: NetworkAvailabilityProvider`。
- **三条前进路径汇入同一处判定**（`tryOfflineAdvance`，收口唯一）：

| 路径 | 入口 | 判定调用点 |
|---|---|---|
| 自然播完推进 | `PlaybackEvent.EnginePlaybackCompleted` | `dispatch(event)`（`replayCurrentFirst = true`） |
| 解析失败自动跳歌 | `RecoveryOrchestrator.maybeAutoSkip` → 自派发 `Next(autoPlay = true)` | `dispatch(intent)`（`replayCurrentFirst = false`） |
| 用户手动下一首 | `PlaybackIntent.Next` / `PlayerCommand.Next` | `dispatch(intent)`（`replayCurrentFirst = false`） |

- 判定流程：`!networkAvailable` → 归约结果确属「前进」（`isOfflineFilterableForward()`，**用归约器自身产出
  判定**，不重推索引算术）→ 队列非退化 → `startOfflineAdvance`。
- 候选枚举复用 `PlaybackQueue.nextCandidateIndices()`（循环/随机/队尾截断语义的唯一入口）；`ONE` + 播完时
  把当前下标置于首位；单曲 + `ONE` 取当前下标。
- 挂起查询逐个 `resolveCachedSource`，命中者记入映射 → 纯策略 `choose` → `Play` 则
  `playCachedCandidate(index, source)` → **单次派发** `PlaybackIntent.PlayAt(index, source)`
  （`PlayAt` 新增可选参数 `source`，默认 `null` = 与改造前逐字一致；非 null 时归约器**先**把该源
  回写进队列项、**再**以带 URL 的曲目起播）；`Stop` 则 `dispatch(PlaybackIntent.OfflineNoPlayableCache)`。

> **实现期缺陷与修复（2026-10-16，登记）**
> 初版实现为「先 `dispatch(UpdateSong(song.copy(url = source)))` 回写，再 `dispatch(PlayAt(index))`」。
> 该写法在本工程**不生效**，且会**击穿 R-1/R-2**：
> 1. `Song.equals` **仅按 `id` 比较**（`N/…/data/model/Song.kt:123-127`），故纯字段级更新使
>    `state.copy(queue = updated)` 与旧 state **结构性相等**；
> 2. `PlaybackStore.apply` 的 `_state.value = transition.state`（`PlaybackStore.kt:502-505`）被
>    `MutableStateFlow` 的**相等去重吞掉** → url 回写不落入 state；
> 3. 随后 `PlayAt` 读到的 `url` 仍是旧值/`null` → `needsUrlResolution(song)`（`PlaybackReducer.kt:1166-1167`）
>    为真 → `launchSong` 产出 `ResolveSongUrl`（**离线必失败**）→ 引擎错误 → 恢复链 SKIP →
>    再次离线枚举 → 全未命中 → `OfflineNoPlayableCache`。**结果：明明有已缓存曲，却停播并报
>    「网络不可用，歌单中无已缓存歌曲」。**
>
> **修法**：把**回写与起播合并为一次状态迁移**（`PlaybackIntent.PlayAt(index, source)`）。
> `launchSong` 必然改变 `isResolvingUrl` / `awaitingPlaybackProgress` / `position` / `queueRevision`，
> 故该迁移**不可能**被 `MutableStateFlow` 去重吞掉。由 `OfflineAdvanceStoreTest` 的回归用例锁定
> （候选曲 `url` 为 `null` 与为**陈旧值**两种形态，均断言「以记忆源起播」+「队列项 url 已回写」）。
>
> **修复实证（同一探针，回退生产改动 vs 修复后）**：
> - 修复前（候选曲 `url == null`）：`engine.calls=[prepare:a:null:true, pause]`、`resolveError=网络不可用且歌单中无已缓存歌曲`、
>   `queue.playlist[2].url=null`，且 `resolveCalls=[b, c, a, b]`（首轮命中 c 但回写被吞 → `ResolveSongUrl` 离线失败 → 恢复链二次枚举）；
> - 修复后：`engine.calls=[prepare:a:null:true, prepare:c:null:true]`、`resolveError=null`、`queue.playlist[2].url=https://cdn.example/c`。
>
> 同批修复的同类缺陷：**候选探测命中后未短路**（`startOfflineAdvance` 原会探测完全部候选），
> 与 `OfflineAdvancePolicy` KDoc 声明的「惰性短路由调用方保证」不符，且造成无谓磁盘 I/O；
> 已改为命中首个可播缓存即 `break`（`resolveCalls` 由 `[b, c, d]` 收敛为 `[b, c]`，决策结果不变）。
- **代次校验**：捕获 `activeRequestGen`，每次挂起返回后与派发前都过 `requestGate.isCurrent(gen)`
  （**复用既有 `PlaybackRequestGate`，不引入第三套代次体系**）；枚举期间用户发出新播放族意图 → 本轮放弃、
  **不写任何状态**。
- **资源与取消**：枚举任务绑 `offlineAdvanceJob`（可取消）；新一轮枚举先取消上一轮；`Stop` / `ClearQueue` /
  新播放族意图到达时取消；`scope` 取消时随作用域释放。决策落定后**先置空引用再派发**，避免自身派发的
  `PlayAt` 触发自取消。无界 Channel / 无界队列 / 永久运行协程一律禁止。
- **归约器保持纯函数**：网络查询（同步端口）在 `tryOfflineAdvance`；缓存查询（挂起 I/O）在
  `startOfflineAdvance` 的受控协程；归约逻辑内无 I/O、无网络、无播放器操作。
- 缓存键音质档**唯一来源** `cacheQualityOf(song) = song.quality ?: PlaybackCacheKeys.DEFAULT_QUALITY`，
  与引擎写入路径**逐字同源**。

### 4.5 恢复链收口（S5，R-4）

- `PlaybackStore.dispatch(event)` **移除** `PlaybackEvent.NetworkChanged → recovery.onExternalRecoveryTrigger()`
  连线；`NetworkChanged` 归约仍只写 `isWifiNetwork` 标志，不产生任何播放/重试动作。
- `RecoveryOrchestrator.onExternalRecoveryTrigger()` 的能力**保留**（KDoc 已改写为「回到前台 / 其它外部信号」），
  当前唯一调用方是 `PlaybackEvent.AppForegroundChanged`（`!backgrounded`）。
- 离线期间的失败：`classifyPlaybackRecoveryFailure(networkAvailable = false)` →
  `NETWORK_UNAVAILABLE` → `attemptRecovery` 在该分类门**之后**才 `budget.tryConsume`，故
  离线失败**不消耗恢复预算、不排期退避**（`RecoveryOrchestrator` KDoc 与 `isNetworkAvailable()` KDoc 已同步改写）。

### 4.6 新增意图与展示文案

- `PlaybackIntent.OfflineNoPlayableCache`（`N/…/player/state/PlaybackIntent.kt`）：**不复用 `Stop`**
  （`Stop` 会 `invalidatePlaybackRequest()` 并作废请求代次），**不伪造引擎错误**（避免污染错误分类与恢复链）。
- `PlaybackReducer.offlineNoPlayableCache(state)`：保留 `queue` / `currentIndex` / `currentSong` / 位置基准；
  `isPlaying = false`、`playbackNotReady = true`、`awaitingPlaybackProgress = false`、`isResolvingUrl = false`、
  `manualRetryInFlight = false`、`resolveError = "网络不可用且歌单中无已缓存歌曲"`；效果 = `Pause` + `StopKeepAlive`
  （**不发 `Stop`**）。
- `PlaybackErrorMessages.safePlaybackErrorMessage`：原始串 `"网络不可用且歌单中无已缓存歌曲"` →
  展示串 `"网络不可用，歌单中无已缓存歌曲"`（Dart 的 6 条映射与兜底语义不变）。
- `isRecoveryCancellingIntent` 收录 `OfflineNoPlayableCache`（终态，旧恢复任务应被取消）。

### 4.7 文件清单

**新增生产文件（8）**：`player/offline/` 下 `AndroidNetworkAvailabilityProvider.kt`、
`NetworkAvailabilityProvider.kt`、`OfflineAdvancePolicy.kt`、`PlaybackCacheKeys.kt`、`PlaybackCacheResolver.kt`、
`PlaybackCacheStore.kt`、`ResolvedSourceMemory.kt`、`SimplePlaybackCacheResolver.kt`。

**修改生产文件（9）**：`store/PlaybackStore.kt`、`store/PlaybackReducer.kt`、`store/RecoveryOrchestrator.kt`、
`state/PlaybackIntent.kt`、`di/PlayerModule.kt`、`engine/AudioEngineConfig.kt`、`engine/AudioEngineFactory.kt`、
`engine/ExoPlayerPlaybackEngineAdapter.kt`、`model/PlaybackErrorMessages.kt`；构建（2）：`app/build.gradle.kts`、
`gradle/libs.versions.toml`。

**新增测试文件（6）**：`player/offline/{AndroidNetworkAvailabilityProviderTest, OfflineAdvancePolicyTest,
PlaybackCacheEngineWiringTest, PlaybackCacheStoreTest, SimplePlaybackCacheResolverTest}.kt`、
`player/store/OfflineAdvanceStoreTest.kt`。

**修改测试文件（4）**：`store/{PlaybackStoreTest, RecoveryOrchestratorTest, HighFrequencyChannelTest}.kt`
（仅注入「在线」假端口，保证既有用例离线分支不可达、行为零变化）、`store/PlaybackReducerTest.kt`
（新增 `OfflineNoPlayableCache` 归约断言）。

## 5. 行为规格与边界

### 5.1 前进路径收口

```
输入：currentIndex、playlist、loopMode、isOffline、cached(i) 判定
若 isOffline == false：走既有路径（完全不变）
若 isOffline == true：
  按 loopMode 从 currentIndex 出发向后枚举候选（复用 PlaybackQueue.nextCandidateIndices）
  对每个候选索引 i（惰性、短路）：若 cached(i)：切到 i 并播放，结束
  若枚举完仍无可播缓存候选：停止播放（R-3）
```

- 判定是**挂起**操作，经 Store 的受控执行器；**不得**在归约器内做 I/O。
- 每个候选判定都做代次校验：用户在枚举期间发出新播放意图 → 立即放弃本轮枚举。

### 5.2 循环模式边界（**已实现**，依据 `PlaybackQueue.nextCandidateIndices()` 逐行语义）

| loopMode | 实际行为 |
|---|---|
| `ALL`（列表循环） | 从 `currentIndex+1` 向后找，绕回队首继续找，最多 `playlistSize-1` 个候选 |
| `OFF`（顺序） | 从 `currentIndex+1` 向后找；**起始位即队尾时仍会绕回队首方向**（`PlaybackQueue.nextCandidateIndices()` 的 Dart `(_currentIndex + 1) % n` 语义）。**刻意如此**——对应需求原文「**循环到**歌单下一首已缓存歌曲，**若存在可播放的缓存歌曲则继续播放，若无任何可播放的歌曲则停止播放**」：这是**全歌单存在性**判定，而非「仅看当前索引之后」。故离线路径**不**复用 `nextBoundary` 的 `HintAndPause` 守卫；该行为已由 `OFF_离线队尾_绕回队首方向命中已缓存曲并起播` 锁为显式契约 |
| `ONE`（单曲循环） | 播完触发时当前下标置于候选首位：当前曲已缓存 → 重播当前曲；未缓存 → 继续向后找（**不**在未缓存曲上原地重播） |
| 随机（shuffle） | 沿用 `PlaybackQueue` 既有候选顺序，只对候选做「是否已缓存」过滤 |

### 5.3 其它边界

| 场景 | 实际行为 |
|---|---|
| 空队列 / 无效索引 | 不启动枚举、不写状态（`tryOfflineAdvance` 直接返回 `false`，走既有归约） |
| 队列只有一首且未缓存 | 停止播放（R-3） |
| 队列只有一首且已缓存（`ONE`） | 重播当前曲 |
| 用户手动切到某曲（`PlayAt` / `PlaySingleSong`） | 用户意图优先：**不做**缓存过滤（走正常解析路径） |
| 离线时用户手动点「下一首」 | **同样**按 R-1 过滤到已缓存曲目（决策 Q5） |
| 听书付费章节（`Song.isLongAudio`） | 沿用既有契约：不自动跳（与 `RecoveryOrchestrator.maybeAutoSkip` 一致） |
| `Previous`（上一首） | **不**做缓存过滤（产品需求只提「下一首」）；登记为待确认项 |
| 网络恢复 | **不**自动续播、**不**自动重试；仅恢复「可解析」能力（R-4） |

## 6. 明确决策登记（原设计稿 Q1–Q6 落定）

| # | 问题 | 决议 | 依据 |
|---|---|---|---|
| **Q1** | 循环模式边界（尤其 `ONE` 在「当前曲未缓存」时） | 复用 `PlaybackQueue.nextCandidateIndices()` 的既有语义 + `ONE` 播完先判当前曲；单曲 + `ONE` 取当前下标 | 交接铁律：索引算术必须逐行模拟 Dart，由 `PlaybackQueue` 独家承担 |
| **Q2** | R-3「停止播放」= `Stop` 还是 `Pause`？ | **`Pause` + 保留队列 + `resolveError` 错误态**（新意图 `OfflineNoPlayableCache`） | 需求只要求「停止播放」，未要求清空歌单；清队列会让用户丢失播放上下文 |
| **Q3** | 缓存层未就绪时网络端口能否单独接线 | **必须同时接线**（缓存 + 网络）；生产 `PlayerModule` 已同时绑定 `SimplePlaybackCacheResolver` + `AndroidNetworkAvailabilityProvider` | 若只接网络而缓存为 `NoOp`，所有曲目判未缓存 → 离线立即停播 |
| **Q4** | 播放缓存写入策略 | **边播边写**（`CacheDataSource` 透明写）+ 上限 **512 MiB LRU**（常量，待 F-CACHE-009 接线） | 最小范围；**不得**演变为离线下载（产品约束 4） |
| **Q5** | 离线时**用户手动**点「下一首」是否做缓存过滤 | **做**（否则会立刻解析失败） | 与 R-1 一致；用户点「下一首」的意图是「换一首能放的」 |
| **Q6** | 归入 P1 还是 P2 数据层 | **P1**（工作区路线图 T-P1-13） | 实现落在 `player/` 域；不依赖 P2 数据层 |

## 7. 测试

### 7.1 新增测试（`player/offline/`，51 条）

| 文件 | 条数 | 覆盖要点 |
|---|---|---|
| `OfflineAdvancePolicyTest.kt` | 9 | 空候选/全未缓存 → Stop；首个命中即选中并**短路**；跳过连续未缓存；负下标不参与；候选顺序即优先级 |
| `PlaybackCacheStoreTest.kt` | 18 | 完整/部分/未知长度判定；hole（`!isCached`）不算已缓存；span 空隙；多段覆盖；键隔离；LRU 淘汰后判定翻转；源记忆读写/覆盖/跨实例；单例与目录锁；经 `CacheDataSource` 实读完整/部分 |
| `SimplePlaybackCacheResolverTest.kt` | 9 | 未缓存 → `null`；已缓存但未记源 → `null`；只缓存一部分 → `null`；音质档隔离；覆盖旧值；`NoOp` 语义；**经注入调度器派发（不在调用线程内联）**；未缓存时在读源记忆前短路 |
| `AndroidNetworkAvailabilityProviderTest.kt` | 8 | 有 INTERNET → true；无活动网络 → false；缺 INTERNET → false；**无 VALIDATED 仍 true（保守）**；能力集 null → true；查询抛异常 → true；取不到服务 → true；`AlwaysOnline` 恒 true |
| `PlaybackCacheEngineWiringTest.kt` | 7 | `prepare` 的 `MediaItem` 携带 `songId\|quality` 键（含默认档回落）；**缓存键与签名 URL 解耦**（不同 URL 同键）；`AudioEngineConfig` 默认不挂数据源工厂；挂载后引擎可构建且 `prepare` 语义不变；拒绝无音源曲目语义不变；**构建引擎不触发缓存索引加载** |

### 7.2 新增测试（`player/store/OfflineAdvanceStoreTest.kt`，27 条，Store 层集成）

覆盖 R-1 ~ R-4 的端到端路径：离线 `Next` 落到下一首已缓存曲**并以记忆源起播 + 回写队列项**、
离线自然播完推进、候选全未缓存 → `OfflineNoPlayableCache`（队列与当前索引保留 + 错误态 + 无重试 + 无网络解析）、
网络恢复后在 30/60/120s 退避窗口内不自动恢复播放/重试、循环模式矩阵
（`ALL` 队尾绕回 / `OFF` 队尾无可播缓存则停止 / **`OFF` 起始位即队尾时绕回并起播** / `ONE` 播完重播当前曲 /
`ONE` 当前曲未缓存则前进）、空队列不启动枚举不写状态、单曲已缓存重播 / 未缓存停止、
代次校验（枚举在途时新播放族意图 → 迟到枚举被丢弃且不写状态）、取消（`Stop` / `ClearQueue` / 作用域取消 /
连续两次 `Next` 只保留最后一轮）、**候选探测命中即短路**、用户显式选曲（`PlayAt` / `PlaySingleSong`）不做过滤、
缓存键一致性（无音质档回落 `DEFAULT_QUALITY` / 有音质档用该曲档）、
**回归用例**：候选曲 `url` 为 `null` 与为**陈旧值**两种形态均以记忆源起播并回写队列项（锁定 §4.4 的实现期缺陷）。

### 7.3 归约器测试（`PlaybackReducerTest.kt` 追加，+4 条）

- `OfflineNoPlayableCache` 的归约结果：`queue` / `currentIndex` / `currentSong` / `position` /
  `platformPosition` / `duration` **全不变**；`isPlaying=false`、`playbackNotReady=true`、
  `awaitingPlaybackProgress=false`、`isResolvingUrl=false`、`manualRetryInFlight=false`、
  `resolveError` 为原始串；效果恰为 `[Pause, StopKeepAlive]`（**不含 `Stop`**）。
- 与 `PlaybackIntent.Stop` 的差异断言（`Stop` 清基准 / 发 `Stop` / 清错误；本意图保留基准、不发 `Stop`）。
- `PlayAt(index, source)` → 队列项 `url` 被回写 + `isResolvingUrl == false` + 效果为 `Prepare`（带该 url）。
- `PlayAt(index)`（`source` 省略）→ 与改造前一致（`url` 为 null 时走 `ResolveSongUrl`）。

### 7.4 测试增量（可复算）

| 阶段 | 测试数 | 增量 |
|---|---|---|
| 本阶段开工基线（`e1265c1`） | 690 | — |
| `player/offline/*Test`（5 文件） | 741 | +51 |
| `OfflineAdvanceStoreTest` | 768 | +27 |
| 缺陷修复回归 + 归约器补测 | **772** | +4 |

`--rerun-tasks` 实测 **772 / 0 失败 / 0 错误 / 0 跳过**；**无既有测试被删除、弱化或跳过**。

### 7.5 未覆盖 / 不可覆盖

- **真机行为**：断网切歌、缓存命中率、弱网恢复、Android 7–9 兼容 —— 沙箱无设备，**未执行**。
- **「非空队列 + `currentIndex` 越界」**：公开 API 无法构造（`PlayPlaylistFrom` / `PlayAt` / `queue.load` /
  `positionedAt` 全部钳位或拒绝），`tryOfflineAdvance` 第③步的越界分支属**防御性代码**，仅覆盖「空队列」。
- **听书付费章节的离线路径**：既有「不自动跳」守卫在 `RecoveryOrchestrator.maybeAutoSkip`
  （**错误驱动、与离线无关**）；离线前进（`Next` / 播完）**不经过**该守卫，也不应被其阻断，
  故只断言「离线前进仍按缓存过滤」，**未**硬造不可达断言。
- **`source` 非 null 且候选下标越界**：由归约器既有越界分支 `unchanged` 拒绝，未新增专门用例。

## 8. 验证结果

见 `docs/native/phase-5-validation.md`（同批提交）——逐条命令、退出码、测试数、失败数均为实测。

## 9. 与 Dart 原实现的差异登记

- Dart **没有**「离线跳歌到已缓存曲目」的显式实现：`next()` 内的自动跳过（`player_provider.dart:4588-4625`）
  只跳过**解析失败**的曲目，不做缓存判定；缓存命中只发生在**起播时**
  （`playOnlineSong` / `playOnlinePlaylist` 的 `cachedPath != null` 分支）。
  故本需求属**产品新增行为**，**无可 1:1 迁移的 Dart 资产**；Dart 的 `resolveLocalAudioPath` 钩子与
  `_lastHasNetwork` 仅作为**端口语义**参考。
- **返回值的形态不同**：Dart `resolveLocalAudioPath` 返回**本地绝对路径**；native 返回**上次成功解析到的
  音源 URL**。原因是 native 的缓存是 Media3 `CacheDataSource` 的**透明读缓存**——命中时引擎仍按**原 URL**
  打开，由 `CacheDataSource` 内部改读缓存文件，播放项因此无需改写 URI。
- **新增写入口** `rememberResolvedSource`：Dart 侧缓存路径与解析结果同源、无需单独记忆；native 的
  `CacheDataSource` 只缓存**字节**，不知道「这段字节属于哪首歌」，故需把「`songId|quality` → 上次解析到的
  URL」单独持久化，离线时才能重建可播放的播放项。
- **网络恢复触发语义反转**：Dart `_onNetworkChanged → _retryFailedPlayback()` 是「网络恢复即自动重试」；
  native 按产品决策 4 **移除**该触发（R-4）。
- **`NET_CAPABILITY_VALIDATED` 不要求**（见 §4.2 偏离登记）。
- **`PlaybackIntent.PlayAt` 新增可选参数 `source`**（Dart `playSongAt` 无此参数）：离线前进必须把
  「记忆到的源」与「起播」**合并为一次状态迁移**（原因见 §4.4 的实现期缺陷）。默认 `null`，
  **既有调用点零行为变化**；`PlayAt` 的 `equals` 会把 `source` 纳入比较，仅在显式传入不同 `source` 时不再相等。

## 10. 未完成项与遗留风险

### 10.1 未完成项（如实登记）

- ❌ **真机验证**：断网切歌、缓存命中、网络恢复不续播 —— **未执行**（沙箱无 Android 设备/模拟器）。
- ❌ **缓存大小设置接线**（F-CACHE-009）：当前为常量 512 MiB，未读用户设置。
- ❌ **缓存索引迁移**：仍用 `SimpleCache` 2 参 legacy 索引（官方标注大缓存下性能较差）。
- ❌ **源记忆加密**：`SharedPreferencesResolvedSourceMemory` 为 `MODE_PRIVATE`（应用隔离），**未**用
  `EncryptedSharedPreferences`。
- ❌ **`Previous` 方向缓存过滤**：未收编（待产品确认）。
- ❌ **`AppForegroundChanged` 生产者**：仍无生产者（R4-01 开放）；详见 §10.2 R5-03。

### 10.2 遗留风险

| # | 风险 | 说明 | 缓解 |
|---|---|---|---|
| **R5-01** | 缓存键一致性 | `songId\|quality` 必须在引擎写入 / 命中查询 / 源记忆三处同源；若任一改为用户设置档位则缓存永不命中 | 已收敛到 `PlaybackCacheKeys.key` + `cacheQualityOf` 单一来源；单测断言键一致 |
| **R5-02** | 接线顺序 | 若网络端口已接而缓存实现为 `NoOp`，离线会立即停播 | 生产 `PlayerModule` 同时绑定两个端口；KDoc 显式警告 |
| **R5-03** | `AppForegroundChanged` 触发路径 | `onExternalRecoveryTrigger()` 仍挂在「回到前台」上。当前**无生产者**故不可达；但若将来接入前后台信号，**离线失败 + 网络恢复 + 用户回到前台**这一组合会经该路径自动重试，**与 R-4 的意图相悖** | 已在 `RecoveryOrchestrator.onExternalRecoveryTrigger` KDoc 写明「调用方**必须**确保它不会被『网络由离线转在线』这一事实驱动」；**接入 T-P1-08 前后台信号时必须复核 R-4** |
| **R5-04** | 真机未验 | 断网/弱网/缓存命中率/Android 7–9 行为均未实测 | 见 §11 |
| **R5-05** | legacy 缓存索引性能 | `SimpleCache` 2 参构造在大缓存下性能较差（官方 `@Deprecated` 标注） | 512 MiB 上限 + 条目数百量级；登记为 F-CACHE-009 接线时一并迁移 |
| **R5-06** | 离线期间回写的签名 URL 可能过期 | `playCachedCandidate` 会把记忆到的源写回队列项；离线切到的曲目在队列里留下可能已过期的 URL | 与既有行为一致（任何解析成功的曲目 URL 都会留在队列里被复用）；在线重试路径 `RetryCurrent` 会先清 URL 再重解析 |
| **R5-07** | 缓存降级档位 | 解析可能降级（`actualPlayingQuality` 与 `Song.quality` 不同），但引擎**始终**按 `Song.quality` 写键；语义为「键代表请求档、字节可能是降级档」 | 查询侧同按 `Song.quality` 即命中；登记为偏离 |
| **R5-08** | **`Song.equals` 仅比 id → 所有「纯字段级回写」都会被 `MutableStateFlow` 相等去重吞掉**（**横切风险**） | 本阶段发现的 D1 缺陷只是该性质的一个实例：`PlaybackStore.apply` 的 `_state.value = transition.state` 依赖结构性相等，而 `Song.equals`（`Song.kt:123-127`，对位 Dart `song.dart:215-221`）**只比 `id`**，故任何「只改 `Song` 字段、不改其它状态字段」的迁移都会被静默丢弃。**凡新增此类回写路径都必须自查** | 离线路径已改为「回写与起播合并为一次迁移」；建议后续**统一评审**所有 `UpdateSong` 纯字段回写调用点（不只播放域），必要时改为「迁移必带一个非 `Song` 字段变化」或显式版本号。**本阶段未越界改动其它域** |

## 11. 真机验证限制

**本阶段未执行任何真机/模拟器验证**（沙箱无 Android 设备与模拟器）。以下行为**不得**据本文宣称可用：

1. 断网时在线歌单的跳缓存曲行为与缓存命中率；
2. 网络恢复后「不自动续播」的真机表现（含通知栏 / 媒体键路径）；
3. `SimpleCache` 在真机文件系统上的索引加载耗时与主线程影响；
4. `ConnectivityManager` 在 OEM 定制 ROM 上的判定表现；
5. Android 7–9（API 24–28）兼容性。

进入后续阶段前必须补做：**一轮真机断网/恢复基线**（否则离线判定与恢复链耦合，难以定位问题）。
