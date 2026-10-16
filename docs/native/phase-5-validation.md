# 第五阶段 · 验证报告（phase-5-validation）

> 本报告记录第五阶段（T-P1-13 离线歌单播放）的**实际执行**验证命令、退出码与结果。
> **纪律**：所有「通过」均附命令与可复算的数字；未执行的项一律标注「未执行」，
> **不以「编译成功」替代验收**，不估算。

---

## 0. 环境与基线

| 项 | 值 |
|---|---|
| 仓库 | `C:/Users/hwx1254427/WorkBuddy/md3Music-native`（工程在 `native/`） |
| 分支 | `native` |
| 执行前 HEAD | `e1265c1b6708795a3cf2c2295214129b467f508b`（第四阶段 T-P1-04 + T-P1-06） |
| 执行前工作区 | 含**未提交**的离线歌单播放实现（`player/offline/` 等）——本阶段在其上继续 |
| JDK | `~/dev-tools/jdk-17.0.20.1+1`（AGP 9 需 JDK17） |
| SDK | `~/dev-tools/android-sdk`（`native/local.properties` 指向本机路径，被 `.gitignore` 排除） |
| 本阶段开工单测基线 | **690 / 0 失败 / 0 错误 / 0 跳过**（`e1265c1` 状态，`--rerun-tasks` 实测） |
| 真机 / 模拟器 | **无**（沙箱无设备） |
| Rust 工具链 | `cargo` **未安装**（`which cargo` → not found），故未执行任何 Rust 测试；本阶段 Rust 源码零改动 |

---

## 1. 逐项命令与结果

| # | 命令 | 退出码 | 结果 |
|---|---|---|---|
| 1 | `./gradlew :app:testDebugUnitTest --rerun-tasks` | 0 | BUILD SUCCESSFUL；**suites=54 / tests=772 / failures=0 / errors=0 / skipped=0** |
| 2 | `./gradlew :app:assembleDebug` | 0 | BUILD SUCCESSFUL |
| 3 | `./gradlew :app:lintDebug` | 0 | BUILD SUCCESSFUL；报告 `app/build/reports/lint-results-debug.html` |
| 4 | `./gradlew :app:assembleDebugAndroidTest` | 0 | BUILD SUCCESSFUL（androidTest 编译门禁） |

> 命令 1-4 合并为一次 Gradle 调用执行（`./gradlew :app:testDebugUnitTest --rerun-tasks :app:assembleDebug :app:lintDebug :app:assembleDebugAndroidTest`），退出码 0。
> AGP 9.0.1 **无 `testReleaseUnitTest` 任务**，单测一律使用 `:app:testDebugUnitTest`。

### 1.1 单测增量（可复算）

| 阶段 | 测试数 | 增量 |
|---|---|---|
| 本阶段开工基线（`e1265c1`） | 690 | — |
| `player/offline/*Test`（5 文件：`OfflineAdvancePolicyTest` 9 / `PlaybackCacheStoreTest` 18 / `SimplePlaybackCacheResolverTest` 9 / `AndroidNetworkAvailabilityProviderTest` 8 / `PlaybackCacheEngineWiringTest` 7） | 741 | +51 |
| `player/store/OfflineAdvanceStoreTest.kt`（Store 层集成，27 条） | 768 | +27 |
| 缺陷修复回归 + 归约器补测（`PlaybackReducerTest` +4） | **772** | +4 |

`suites` 由 48 → 54。**无既有测试被删除、弱化或跳过**（`skipped=0`）。

### 1.2 lint 结果核验

`:app:lintDebug` 输出：`Lint found 2 warnings (and 3 errors and 88 warnings filtered by baseline lint-baseline.xml)`。

可见的 2 条告警**均落在本阶段未改动的文件**，属既有告警：

| 告警 | 位置 | 是否本阶段引入 |
|---|---|---|
| `NewerVersionAvailable`（okhttp 4.12.0 → 5.5.0） | `native/gradle/libs.versions.toml:23` | **否** |
| `UseKtx`（建议用 `SharedPreferences.edit` KTX 扩展） | `native/app/src/main/kotlin/com/gracemusic/data/source/LoudnessStorePrefs.kt:45` | **否**（T-P1-05 交付文件） |

**`app/lint-baseline.xml` 未被修改**（`git status` 无该文件；未通过扩大 baseline 隐藏新增问题）。

> 说明：本阶段新增文件 `player/offline/ResolvedSourceMemory.kt` 初版用 `prefs.edit().putString(..).apply()`，
> 触发一条**新增** `UseKtx` 告警（可见告警由 2 → 3）。已改用 core-ktx 的 `prefs.edit { putString(..) }`
> （默认 `commit=false`，语义等价），**新增告警归零**，可见告警回到 2 条。

---

## 2. 开发过程中的失败与修复（如实记录）

| # | 阶段 | 现象 | 处置 |
|---|---|---|---|
| 1 | 实现期（缺陷 D1） | 离线命中缓存候选后的「回写记忆源」**不生效**，候选曲 `url == null` 时**击穿 R-1/R-2**（明明有已缓存曲却停播并报「网络不可用，歌单中无已缓存歌曲」）。根因：`Song.equals` 仅比 `id`（`Song.kt:123-127`）→ 纯字段级更新使 `state.copy(queue = updated)` 与旧 state 结构性相等 → `PlaybackStore.apply` 的 `_state.value = transition.state` 被 `MutableStateFlow` 相等去重**吞掉**；随后 `PlayAt` 读到 `url == null` → `needsUrlResolution` 为真 → `ResolveSongUrl`（离线必失败）。 | **已修复**：把「回写」与「起播」合并为一次状态迁移——`PlaybackIntent.PlayAt(index, source = null)` + `PlaybackReducer.playAt(state, index, source)` + `PlaybackStore.playCachedCandidate` 单次派发。探针实证见 §2.1。 |
| 2 | 实现期（缺陷 D2） | `startOfflineAdvance` 的候选探测**无短路**，命中后仍探测后续候选（`resolveCalls=[b, c, d]`），与 `OfflineAdvancePolicy` KDoc 声明的「惰性短路由调用方保证」不符，且产生无谓磁盘 I/O。 | **已修复**：命中首个可播缓存即 `break`（`resolveCalls` 收敛为 `[b, c]`，`choose` 仍取候选序首个命中，决策结果不变）。 |
| 3 | 实现期（歧义 D3） | `OFF` 模式起始位即队尾时，离线枚举会**绕回队首方向**（`nextCandidateIndices` 的 `(_currentIndex + 1) % n` 语义），与初版设计稿「OFF 到队尾即止」的措辞不符。 | **判定为符合需求**（需求原文「**循环到**歌单下一首已缓存歌曲，**若存在可播放的缓存歌曲则继续播放，若无任何可播放的歌曲则停止播放」= 全歌单**存在性**判定）。故**保持**绕回，改为修正 KDoc 的错误描述，并把该行为**锁为显式契约测试** `OFF_离线队尾_绕回队首方向命中已缓存曲并起播`。 |
| 4 | 测试基建 | 首版测试引用 `PlaybackStoreTest` 的 fake 时发现其为 `private` 嵌套类（同包不可见）。 | 按项目既有约定（`HighFrequencyChannelTest` / `RecoveryOrchestratorTest` 亦各自私有 fake）新建最小 fake，**未复制整个 Harness**。 |

**无一轮以放宽断言、删除用例或屏蔽错误收尾。**

### 2.1 D1 修复实证（同一探针，回退生产改动 vs 修复后）

| 场景 | 修复前 | 修复后 |
|---|---|---|
| 候选曲 `url == null`（真实形态） | `engine.calls=[prepare:a:null:true, pause]`、`resolveError=网络不可用且歌单中无已缓存歌曲`、`queue.playlist[2].url=null`、`resolveCalls=[b, c, a, b]`（首轮命中 c 但回写被吞 → `ResolveSongUrl` 失败 → 恢复链二次枚举） | `engine.calls=[prepare:a:null:true, prepare:c:null:true]`、`resolveError=null`、`queue.playlist[2].url=https://cdn.example/c` |
| 候选曲 `url` 为陈旧值 | `prepare:c:url=<旧值>`（回写未生效） | `prepare:c:url=<记忆源>` + 队列项 url 已回写 |

对应回归用例：`R1_R2_离线前进回写记忆源生效_候选url为空时以记忆源起播`、
`R1_R2_离线前进_候选url为陈旧值_以记忆源起播并回写队列项`。

---

## 3. 未执行 / 未验证项（明确列出）

| 项 | 原因 | 归属 |
|---|---|---|
| 真机断网时在线歌单的跳缓存曲行为与缓存命中率 | 沙箱无设备 | 用户实测 |
| 真机「网络恢复后不自动续播」（含通知栏 / 媒体键路径） | 沙箱无设备 | 用户实测 |
| `SimpleCache` 在真机文件系统上的索引加载耗时与主线程影响 | 沙箱无设备 | 用户实测 |
| `ConnectivityManager` 在 OEM 定制 ROM 上的判定表现 | 沙箱无设备 | 用户实测 |
| Android 7–9（API 24–28）兼容性 | 无设备 | 用户实测 |
| 「非空队列 + `currentIndex` 越界」分支 | 公开 API 无法构造，属防御性代码 | 不适用 |
| 听书付费章节的离线专项断言 | 该守卫在 `RecoveryOrchestrator.maybeAutoSkip`（错误驱动、与离线无关），离线前进不经过它，断言不可达 | 不适用 |
| Rust 侧测试 | `cargo` 未安装 | 环境阻塞（本阶段 Rust 零改动） |

---

## 4. 结论

- **代码层**：T-P1-13 已实现并有单测覆盖（本阶段新增 **82** 条：690 → 772）；全量单测 772 全绿，
  Debug 构建、lint、androidTest 编译门禁全部通过；lint 无新增可见告警、baseline 未动。
- **实现期发现并修复 2 个真实缺陷**（D1 回写被 `MutableStateFlow` 去重吞掉、D2 候选探测无短路），
  均由回归用例锁定；1 处歧义（D3 OFF 队尾绕回）经复核需求原文判定为**符合需求**，已锁为契约测试。
- **真机层**：**完全未验证**。所有「离线播放 / 缓存命中 / 网络恢复不续播」的真机可用性声明
  **一律不成立**，须待用户设备实测。
- **未完成项**：缓存大小设置接线（F-CACHE-009）、缓存索引迁移（`StandaloneDatabaseProvider`）、
  源记忆加密、`Previous` 方向缓存过滤、`AppForegroundChanged` 生产者 —— 详见
  `docs/native/phase-5-offline-playlist.md` §10。
- **阶段边界**：T-P1-07 / T-P1-08 / T-P1-09 / T-P1-10 / T-P1-11 / P2 / P3 **均未实现**（本阶段未越界）；
  未引入 USB 独占、离线下载、下载队列、断点续传或 `depth3d`。

---

# 第五阶段（第二批）· 验证报告：T-P1-08 + T-P1-10/11

> 上面 §0–§4 是 **T-P1-13**（离线歌单播放，提交 `908d349`）的验证记录，原样保留。
> 本节记录**同一阶段第二批**交付（T-P1-08 音频焦点运行时 + T-P1-10/11 持久化与数据层基础）的验证结果。

## 5. 环境与基线

| 项 | 值 |
|---|---|
| 仓库 | `C:/Users/hwx1254427/WorkBuddy/md3Music-native`，分支 `native` |
| 开工 HEAD | `2942909`（`docs(native): add consolidated phase-4 delivery report`，未推送） |
| 开工基线测试 | **772 tests / 0 failures / 0 errors / 0 skipped**（54 suites，`--rerun-tasks` 实测） |
| 工具链 | JDK 17（`~/dev-tools/jdk-17.0.20.1+1`）、AGP 9.0.1、Kotlin 2.3.20、KSP 2.3.12 |
| 设备 | **无**（沙箱无 Android 设备/模拟器） |

## 6. 逐项命令与结果（均为实测，非估算）

| # | 命令 | 退出码 | 结果 |
|---|---|---|---|
| 1 | `./gradlew projects` | 0 | BUILD SUCCESSFUL（`:app` + `:media3fork`） |
| 2 | `./gradlew :app:testDebugUnitTest --rerun-tasks` | 0 | **suites=60 / tests=874 / failures=0 / errors=0 / skipped=0** |
| 3 | `./gradlew :app:assembleDebug` | 0 | BUILD SUCCESSFUL |
| 4 | `./gradlew :app:lintDebug` | 0 | BUILD SUCCESSFUL；可见告警均为既有，**无本阶段新增**；`lint-baseline.xml` **未修改** |
| 5 | `./gradlew :app:assembleDebugAndroidTest` | 0 | BUILD SUCCESSFUL |
| — | Rust 测试 | — | **未执行**（`cargo` 未安装；本阶段 Rust **零改动**） |

### 6.1 测试增量（可复算）

| 批次 | 新增 | 累计 |
|---|---|---|
| 开工基线 | — | 772 |
| T-P1-08（`AudioFocusControllerTest` 22 + `AudioFocusStoreTest` 14 + `PlaybackReducerTest` +7） | +43 | 815 |
| T-P1-10/11（`PlaybackQueueCodecTest` 15 + `PlaybackCursorStoreTest` 19 + `PersistenceWiringStoreTest` 11 + `PlaybackReducerTest` +6） | +51 | 866 |
| T-P1-13 边界补齐（`OfflineCacheBoundaryTest` 11） | +11 | **877** |

> 实测 XML 汇总为 **874**（与上表 877 差 3）：`PlaybackReducerTest` 的 3 条既有用例被**改写**（非新增），
> 上表按「新增方法」计数，XML 按「当前存在的用例」计数。差异已核实，非遗漏。

### 6.2 lint 核验

- 本阶段新增文件（`AudioFocusController` / `Media3AudioFocusEventSource` / `AudioFocusEventSource` /
  `AppForegroundMonitor` / `ProcessLifecycleAppForegroundMonitor` / `PlaybackQueueCodec` /
  `PlaybackCursorStore`）**无新增可见告警**；
- `PlaybackCursorStore` 的 `Context` 参数未加 `@ApplicationContext`（改为由 DI 的 `@Provides` 显式构造），
  避免 Hilt 对默认参数（io 调度器）的解析失败；
- **未**扩大 `lint-baseline.xml`。

## 7. 开发过程中的失败与修复（如实记录）

| # | 现象 | 根因 | 修复 |
|---|---|---|---|
| 1 | `AudioFocusStoreTest` 5 条断言失败（`isPlaying`） | `isPlaying` 是**引擎权威值**，由 `EngineIsPlayingChanged` 事件驱动；暂停归约**不**改它 | 修正断言：先 `emitIsPlayingChanged(false/true)` 再断言 |
| 2 | `AudioFocusControllerTest`/`AudioFocusStoreTest` 平台签名冲突 | fake 的 `var forcedWillPauseWhenDucked: Boolean?` 生成的 setter 与接口方法 `setForcedWillPauseWhenDucked(Boolean?)` 同签名 | 属性改名 `lastForcedWillPauseWhenDucked` |
| 3 | `AudioFocusStoreTest` 编译失败：嵌套类不能访问外层类成员 | `Harness` 非 `inner`，无法调外层类的 `localSong` / `converge` | 改为文件级 `private fun` + fake 的成员方法 |
| 4 | `PlaybackReducer` 语法错误 | Edit 时误删 `setIgnoreAudioFocus` 的 KDoc 首两行 | 补回 `/**` + 首行 |
| 5 | Hilt `[Dagger/MissingBinding] PlaybackPersistence` | 注入点声明接口，实现类未绑定 | `PlayerModule` 加 `providePlaybackPersistence` |
| 6 | `ApplicationProvider` 未解析 | 工程无 `androidx.test:core` 依赖 | 改用 Robolectric 的 `RuntimeEnvironment.getApplication()` |
| 7 | `幽灵守卫_队列按当前曲判定` 失败 | 测试用的 `queueOf` 默认构造**在线**曲（不跳过） | 改为显式构造本地曲 |
| 8 | `离线停止后用户手动重试_走既有解析链路` 失败 | `UnconfinedTestDispatcher` 下解析**立即失败**并清 `isResolvingUrl`，`isResolvingUrl` 断言不成立 | 改为断言 fake api 的**解析调用次数**增加（直接验证「重新解析」） |

**上述均为测试侧问题，生产逻辑未因此改动**（唯一的生产侧修正见 §8）。

## 8. 契约演进（非「放宽断言」，逐条登记）

| 变更 | 原契约 | 新契约 | 既有测试处置 |
|---|---|---|---|
| `SetIgnoreAudioFocus` 归约 | 只落盘不写状态 | 写 `PlaybackState.ignoreAudioFocus` + 落盘 | 用例**改写**为 `写内存并落盘` + 新增 `同值无操作` |
| `SetAudioFocusInterruptionMode` 归约 | 只落盘不写状态 | 写 `PlaybackState.audioFocusInterruptionMode` + 落盘 | 同上 |
| `SetRestoreMemoryEnabled` 归约 | 只落盘不写状态 | 写 `PlaybackState.restoreMemoryEnabled` + 落盘 | 同上 |
| `AppForegroundChanged` 归约 | `unchanged` | 写 `PlaybackState.isAppBackgrounded` | 用例**改写**为 `写后台事实字段且不产生效果` + 新增 `同值无操作` |
| `AppForegroundChanged` 消费 | `!backgrounded → onExternalRecoveryTrigger()` | 无播放动作（R-4 复核） | 新增 3 条锁定用例 |

**未删除任何用例、未放宽任何断言、未扩大 lint baseline。**

## 9. 未执行 / 未验证项（明确列出）

| 项 | 原因 | 归属 |
|---|---|---|
| 真机焦点行为（来电/导航/语音助手/拔耳机/蓝牙断开） | 无设备 | 用户实测 |
| 真机杀进程重启还原（队列/进度/音量） | 无设备 | 用户实测 |
| 大队列（数千首）序列化耗时与落盘延迟 | 无设备 | 用户实测 |
| 退桌面/退出时 `flush()` 是否在进程被杀前完成 | 无设备 | 用户实测 |
| `ProcessLifecycleOwner` 在 OEM ROM 上的 700ms 延迟表现 | 无设备 | 用户实测 |
| Android 7–9（API 24–28）兼容路径 | 无设备 | 用户实测 |
| Rust 测试 | `cargo` 未安装 | 环境阻塞（Rust 零改动） |

## 10. 结论

- **代码层**：T-P1-08 与 T-P1-10/11 已实现并有单测覆盖；全量单测 **874 全绿**（772 → 874，+102），
  `projects` / `assembleDebug` / `lintDebug` / `assembleDebugAndroidTest` 全部通过；lint 无新增、baseline 未动。
- **关键验收项已由测试锁定**：系统焦点中断不产生错误效果（不消耗恢复预算）；用户主动暂停不被焦点恢复自动播放；
  前后台事件不驱动任何播放/重试（R-4 复核）；缓存 URL 不落盘；恢复不自动播放；损坏数据不崩溃。
- **真机层**：**完全未验证**。所有「焦点行为正确 / 冷启动还原」的真机可用性声明**一律不成立**。
- **未完成项**：`abortCrossfade()` 接入（T-P1-07 必须补）、`PersistPreference`/`PersistFavoriteToggle` 执行器、
  Room/DataStore 迁移、恢复位置钳位 —— 详见 `phase-5-audio-focus.md` §9 与 `phase-5-data-layer.md` §6。
- **阶段边界**：T-P1-07 / T-P1-09 / P2 / P3 **未实现**（未越界）；未恢复 USB 独占、未引入离线下载。
