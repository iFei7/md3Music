# 第三阶段 · PlaybackStore 归约器、播放引擎与功能闸门接线

> **阶段范围**：路线图 T-P1-01（纯归约器）+ T-P1-02（副作用编排/引擎接线），即用户简报 T45b。
> **基线**：第二阶段提交 `ab9b192`（已推送 origin/native，CI run #11 预构建已触发）。
> **本阶段提交**：`feat(native): implement playback state store and engine wiring`（本地提交，未推送）。
> **测试基线**：343 → **542**（40 个测试类；`--rerun-tasks` 实测 0 失败 / 0 错误 / 0 跳过）。
> **真机验证**：**未执行**（沙箱无设备/模拟器）。本文所有"可用"均指代码路径与自动化测试层面的真实接通，不等于真机行为验证。

---

## 1. PlaybackStore 是什么（职责定位）

`PlaybackStore`（`native/app/src/main/kotlin/com/gracemusic/player/store/PlaybackStore.kt`，690 行）是原生播放状态的**统一归约入口与编排层**：

- 持有唯一的状态快照 `StateFlow<PlaybackState>` 与高频位置流 `StateFlow<Duration>`；
- 把用户意图（`PlaybackIntent`）与已发生事实（`PlaybackEvent`）交给纯归约器 `PlaybackReducer`；
- 按序执行归约产出的副作用（`PlaybackEffect` → 引擎/保活/登记中的数据处理）；
- 实现 `PlaybackSessionBridge`，把系统层（媒体键/通知）的 `PlayerCommand` 翻译为意图；
- 持有并驱动功能闸门管线（代次主轴、位置链、错误入口、CDN 看门狗）。

**它明确不是**：另一个直接控制底层资源的巨大服务。引擎实例（ExoPlayer）生命周期归 `AudioEngine`/DI；系统命令路由归 `PlaybackSessionRegistry`；队列算术归 `PlaybackQueue`（纯函数域）；闸门判定归 `player/gate/`（纯逻辑域）。Store 只做"归约 + 编排"。

## 2. 文件清单（本阶段新增/修改）

| 文件 | 职责 | 测试 |
|---|---|---|
| `player/store/PlaybackReducer.kt` | 纯归约器（零 Android 依赖），双 `reduce` 重载 | — |
| `player/store/PlaybackTransition.kt` | 归约输出（新状态 + 效果列表） | — |
| `player/store/PlaybackEffect.kt` | 副作用密封接口（16 个子类型，数据/系统类标注 TODO 任务编号） | — |
| `player/store/PlaybackEngine.kt` | 引擎最小接口 + `EngineListener` | — |
| `player/store/PlaybackStore.kt` | @Singleton 编排层（状态面/派发/效果执行/桥接/闸门管线/看门狗）+ `@StoreScope` 限定符 | — |
| `player/store/PlaybackKeepAlive.kt` | 保活控制器接口 + Android 实现（转发 `PlaybackKeepAliveService.start/stop`） | — |
| `player/engine/ExoPlayerPlaybackEngineAdapter.kt` | media3 真实适配器（349 行） | — |
| `player/state/PlaybackIntent.kt`（+13 行） | 仅新增事件 `PlaybackProgressConfirmed`（既有子类型零改动） | — |
| `di/PlayerModule.kt`（+48 行） | 仅追加：`providePlaybackEngine` / `providePlaybackKeepAlive` / `provideStoreScope` | — |
| `test/.../player/store/PlaybackReducerTest.kt` | 归约器全量测试（**140** 个 @Test，纯 JUnit 无 Android） | 140 |
| `test/.../player/store/PlaybackStoreTest.kt` | Store 编排测试（**33** 个 @Test，假引擎+假保活+真 registry+真闸门） | 33 |
| `test/.../player/engine/ExoPlayerPlaybackEngineAdapterTest.kt` | 适配器测试（**26** 个 @Test，Robolectric 真 ExoPlayer） | 26 |

## 3. 状态模型（PlaybackState）

沿用 P1-5a 交付的 23 字段快照（`player/state/PlaybackState.kt`），本阶段不增删字段。关键语义：

- **`isPlaying` 唯一权威写入口是 `EngineIsPlayingChanged` 事件**（及 `STATE_*` 终态推导）。播放类意图**不乐观写** `isPlaying`——通知栏 PLAY_PAUSE 由 media3 直接驱动 ExoPlayer（`Md3MediaSessionCallback.kt:99-105` 刻意不投递意图），乐观写会让状态与平台真相脱节。用户按下播放到真正出声之间的间隙由 `awaitingPlaybackProgress` 表达。
- **`position` 与 `platformPosition` 分离**：seek 意图乐观写 `position`；`EnginePositionChanged` 写 `platformPosition`。平台位置落后于乐观目标时的采样被抑制（"平台落后于乐观位置"即手势/乐观窗判据——状态里没有专属手势字段，这是刻意设计，见 §7.4）。
- **两条高频流由 Store 另开**（`PlaybackState.kt:33-38` KDoc 约定）：`position`（~200ms 引擎采样转发，进度条/歌词订阅它）+ 睡眠定时剩余流（T-P1-04/09 未建）。快照只做低频基准（切歌/暂停/seek/错误时刷新）。
- **空队列/未知时长语义**：空队列上一切播放族意图为已定义 no-op（归约器拒绝 + 测试钉死）；`duration = null` 表示未知（未装载/直播/已停止），此时 seek 被拒绝；本地曲目（`localPath`）与在线曲目（`url`，可能为 null 待解析）在 `needsUrlResolution` 处分流。
- **`queueRevision`**：结构性队列变更时 +1（`ToggleLoopMode` 不涨——与 Dart `_applyLoopMode` 一致），是预取票据等后续机制的代次键。

## 4. 事件模型（PlaybackEvent）

词汇表 P1-5a 交付 10 个事件子类型，本阶段**仅新增 1 个**（`PlaybackIntent.kt:234-246`）：

| 事件 | 生产者 | 归约器行为要点 |
|---|---|---|
| `EnginePlaybackStateChanged(Int)` | 适配器 `onPlaybackStateChanged` | IDLE/BUFFERING → `playbackNotReady=true`；READY → false；**ENDED 只写 notReady 不抢写 isPlaying**（保 Completed 守卫） |
| `EngineIsPlayingChanged(Boolean)` | 适配器 `onIsPlayingChanged` | 唯一 isPlaying 写入口；起播清 `manualRetryInFlight` |
| `EnginePositionChanged(Duration)` | Store 位置管线（低频 ~1s + 关键节点） | 写 `platformPosition`，条件同步 `position` |
| `EngineDurationChanged(Duration?)` | 适配器 `onDurationChanged` | 写 `duration` |
| `EngineMediaItemTransition(Int)` | Store 把适配器 `onCurrentSongChanged(mediaId)` 解析为队列下标 | **只确认、不采纳**：与 `currentIndex` 不符 → 过期事件忽略（§7.2） |
| `EnginePlaybackCompleted` | 适配器 STATE_ENDED（仅一次） | 循环语义：ONE→重播 / ALL→推进 / OFF→队尾提示+停机（`nextBoundary()`） |
| `EngineError(String)` | 适配器 `onError`（文案经 `safePlaybackErrorMessage` 收敛）过 ErrorEventGate | 原文入 `resolveError`，停机标志 |
| `NetworkChanged(Boolean)` | 系统网络观测（后续接入） | 写 `isWifiNetwork` |
| `AppForegroundChanged(Boolean)` | 应用前后台观测（后续接入） | 归约层 no-op；Store 内部用于恢复门（T-P1-06） |
| `VolumeChanged(Float)` / `LoopModeChanged(mode)` | 设置域回灌（后续接入） | 对齐内存态 |
| **`PlaybackProgressConfirmed`（新增）** | Store 位置管线经 `PlaybackProgressGate` 确认首次真实推进 | 唯一职责：清 `awaitingPlaybackProgress` |

**为什么新增这一个事件**：`PlaybackState.kt:29-31` KDoc 已约定 `awaitingPlaybackProgress`「在 PlaybackStore 里算出结果后再写入」。进度闸门的确认是 Store 侧算出的事实，若让 Store 绕过归约器直写状态快照，就违反了"PlaybackState 唯一写入方是归约路径"的架构约束（native-architecture.md R3）。该事件不得由引擎直接产生。

**缓冲语义**：缓冲开始/结束由 `EnginePlaybackStateChanged(STATE_BUFFERING)` 表达，不设独立事件（media3 状态机已覆盖，避免词汇表重复抽象）。

## 5. 意图模型（PlaybackIntent）

实测 **42 个意图子类型**（`PlaybackIntent.kt`，六大族）：装载起播 6、传输控制 11、队列编辑 9、偏好设置 13、派生刷新 4、收藏 1。归约器测试以脚本核验 **42/42 全覆盖**（每条 ≥1 正例 + ≥1 边界，`PlaybackReducerTest.kt` 头 KDoc 覆盖矩阵）。

## 6. 归约器规则

`PlaybackReducer`（object，纯函数，同输入同输出；随机子路径经注入的 `random` 参数可复现）：

1. **isPlaying 只由引擎事件写入**（§3）；
2. **position/platformPosition 分离**（§3）；
3. **队列操作一律委托 `PlaybackQueue`** 并消费 `QueueMutation` 标志（`structuralChange→revision+1`；`removedCurrentSong→重定位+重备`；`emptied→停机`）。索引算术只准调用队列既有方法——next/previous 的边界不对称（非列表循环在队尾截断 vs 一路试到队首；绕回时提示+暂停 vs seek(0)）是刻意保留的 Dart 行为；
4. **非法操作明确拒绝**（空队列/无当前曲播放、越界索引、未知时长 seek、ENDED 后 seek → 状态原样 + 空效果）；
5. **Completed 循环语义**用 `nextBoundary()`：ONE→`SeekTo(0)+Play` / ALL→推进（队尾绕回队首）/ OFF→`ShowMessage(队尾提示)+Pause+StopKeepAlive`；
6. **transition 事件按身份对账**（§7.2）。

**与 lite `player_provider.dart` 的 8 项刻意差异**（全文登记于 `PlaybackReducer.kt:57-84`）：①isPlaying 不乐观写；②播完队尾 OFF→提示+停机（Dart 该路径实际为列表循环，与其 `AppLoopMode.OFF` KDoc 自相矛盾，取 KDoc 语义）；③删当前曲后按 `playWhenReady=isPlaying` 重备（不复活用户主动暂停）；④transition 只确认不采纳（Dart 采纳引擎索引）；⑤seek 落点保留乐观值；⑥切歌重置 duration（防旧曲时长泄漏）；⑦恢复类刷新意图为触发器 no-op（Store 读设置后经 `SetAudioQuality` 回灌，保持唯一归约路径）；⑧焦点/记忆类偏好无状态字段，只发 `PersistPreference` 效果。

## 7. 异步事件与过期事件处理

### 7.1 代次主轴（PlaybackRequestGate）

Store 持有唯一 `PlaybackRequestGate`。播放族 12 类意图派发前 `issue()` 记代次（`activeRequestGen`）；`Stop` 后 `invalidate()`（**不更新** `activeRequestGen`——停在最后已发代次上，使停机后的迟到错误 `isCurrent` 为假，对位 Dart `player_provider.dart:602-603`）。代次是进度门/错误门/恢复门的钥匙：所有闸门挂同一代次源，避免代次空间分裂。

### 7.2 身份对账（EngineMediaItemTransition）

适配器按 mediaId（=`Song.id`）身份去重后上报 `onCurrentSongChanged`；Store 把 mediaId 在**当前队列**解析为下标再投事件。单曲时间线下引擎不会自行切歌，故归约器"只确认、不采纳"：与 `currentIndex` 不符即过期（快速切歌的迟到 transition 不会把状态拽回旧曲）。测试：`PlaybackStoreTest.竞态_快速连续切歌后迟到旧曲切换被丢弃`。

### 7.3 粘性 loadCompleted（ErrorEventGate 适配）

`shouldHandlePlaybackErrorEvent(errorCode, isCurrentRequest, loadCompleted)` 的 `loadCompleted` 在 native 用粘性判据「自上次 invalidate 以来有过 Prepare/Play 效果执行」：native 的 seek 不触发重新装载，字面判据会压制 seek 后的中游错误（Dart seek 不触碰请求闸门，同类错误照常上浮）；且 native 无 Dart 的 setUrl Future 通道，装载阶段错误只能在本通道可见——这是对 Dart 语义的 native 适配，已登记。

**errorCode 透传缺口**：适配器 `onError` 仅带收敛文案，不透传 media3 errorCode；Store 传哨兵 `ERROR_CODE_NOT_PROVIDED = -1`（≠ lite 中断码 10000000，native 无该自定义码，语义="非中断错误"）。后果：切歌中断类错误暂无法与真实错误区分，靠代次 + loadCompleted 双条件近似。透传归 T-P1-03/T-P1-06。

### 7.4 seek 乐观窗

`SeekTo/SeekBy` 乐观写 `position`；位置采样中"平台位置落后于乐观目标"的样本被归约器抑制（不回闪），手势完成（`SeekGestureCompleted`）后以平台值为基准收敛。测试：`PlaybackReducerTest.竞态5_*`。

### 7.5 释放后旧事件

双层丢弃：适配器 `released` 标志 + `removeListener`（release 后回调全部丢弃，Robolectric 测试证明）；Store 侧代次检查（停机后迟到错误 `isCurrent` 为假）。测试：`PlaybackStoreTest.释放后引擎回调不改变状态` + 适配器 `release 安全` 2 例。

### 7.6 不用 Mutex 掩盖模型错误

全部派发与效果执行在**调用线程同步完成**，入口契约为主线程（media3 `verifyApplicationThread` 实证）——主线程限定即串行，不引入 Mutex。Store 标注 `@MainThread`；适配器公开方法入口 `checkMainThread()`，非主线程调抛 `IllegalStateException`（适配器测试 11 方法全验）。

## 8. 副作用调度机制

归约器产出 `PlaybackTransition(state, effects)`；Store `apply()` **先发布状态、再按序执行效果**（效果不丢、不乱序）。16 个效果子类型分三类：

| 类别 | 效果 | 执行器 |
|---|---|---|
| 引擎（8） | `Prepare/Play/Pause/Stop/SeekTo/SeekBy/SetVolume/SetSpeed` | `engine.*` 同名真实调用 |
| 服务（2） | `StartKeepAlive/StopKeepAlive` | `keepAlive.*`（Store 侧去重 + 事件路径对账，§10.2） |
| 数据/系统（6） | `ResolveSongUrl/RetryPlayback/PersistPlaybackCursor/PersistFavoriteToggle/PersistPreference/RefreshSystemNotification/ShowMessage` | **TODO 日志 + 任务编号，不伪造成功** |

**数据/系统类效果的接线归属**（如实登记，不得当作已完成）：`ResolveSongUrl`→T-P1-05 音源解析器；`RetryPlayback`→T-P1-06 恢复链（**当前无生产者**，见 phase-3-risks.md R3-06）；`PersistPlaybackCursor`→T-P1-10；`PersistFavoriteToggle`/`PersistPreference`→P2 数据层/设置层；`RefreshSystemNotification`→T-P1-03+（需 session 访问点）；`ShowMessage`→P2 UI 出口。

## 9. 引擎适配层

- **接口**：`PlaybackEngine`（`player/store/PlaybackEngine.kt`，141 行）：`positionFlow` 热流 + 8 个控制方法 + 监听注册 + `release()`。上层（Store/归约器/闸门）只依赖接口，不依赖 media3——Store 测试用假引擎即可验证全部编排逻辑。
- **实现**：`ExoPlayerPlaybackEngineAdapter`（`player/engine/`，349 行），构造参数只有 `AudioEngine`（DI @Singleton @MainThread，`PlayerModule.kt:89`）。
- **单曲时间线**（与 lite `setUrl` 模型一致）：每次 `prepare` 用单个 `MediaItem`（mediaId=`Song.id`）重建时间线；**引擎循环恒关**（`AppLoopMode` KDoc），队列推进全部由 App 层负责——禁止把整个队列塞进时间线让 media3 自动推进（会绕过队尾提示/空队列停机/循环三态语义）。
- **装载拒绝语义**：在线曲目 url 为 null 或本地两字段皆空 → 记录日志后直接返回，不投射、不伪造成功、不崩溃（`PlaybackEngine.prepare` KDoc）。本地曲目音源经 `toFileUri` 逐段 percent-encode（与 Dart `Uri.file` 逐字符一致，跨平台可测）。
- **事件映射**：`onPlaybackStateChanged`（+STATE_ENDED→`onPlaybackCompleted`，按值去重）、`onIsPlayingChanged`、`onDurationChanged`（onEvents 汇总入口去重）、`onCurrentSongChanged`（mediaId 身份对账）、`onError`（文案收敛）。同一事实不重复转发。
- **位置采样**：200ms 节流写 `positionFlow`，仅 `isPlaying || BUFFERING` 时采样（暂停停止空转）。
- **`seekBy`**：media3 1.4.1 无此 API（1.5.0 引入），用 `currentPosition+delta` 的 `seekTo` 实现并注释（适配器 KDoc 登记）。

## 10. 服务与 UI 生命周期边界

### 10.1 四层生命周期

| 层 | 生命周期 | 约束 |
|---|---|---|
| UI（Composable） | Activity/重组 | 只订阅 `state`/`position`、发意图；**不得创建/持有播放器**；`feature/player/PlayerScreen.kt` 仍为路由占位（P3 接入） |
| PlaybackStore | **进程级 @Singleton** | 不随 Activity/Composable 重建；`init` 顺序即契约：字段 → 监听 → 位置管线 → 看门狗 ticker → `registry.attach(this)` |
| 播放引擎（AudioEngine/ExoPlayer） | **进程级 @Singleton**（`PlayerModule.kt:53-57` @MainThread） | Store **不 release 引擎**（进程存续）；release 仅测试与显式拆卸路径 |
| 后台服务 | `Md3MediaSessionService`（media3 会话+通知+前台）+ `PlaybackKeepAliveService`（第二条 IMPORTANCE_MIN 常驻通知） | 一个 Service 同时刻只有一条前台通知，保活通知的价值正是"第二条"（P1-4 设计）；息屏保活由 media3 `C.WAKE_MODE_NETWORK` 承担 |

**Activity 销毁不会释放仍在播放的音频资源**——引擎与 Store 均为进程级单例，与 UI 生命周期解钩。

### 10.2 保活两路驱动（幂等）

- **意图路径**：归约器效果（播放族→`StartKeepAlive`；Pause/Stop/队尾停机→`StopKeepAlive`）；
- **事件路径对账**：`EngineIsPlayingChanged` 变化时按 `state.isPlaying` 对账——覆盖**通知栏 PLAY_PAUSE 不经意图**的路径（media3 直接驱动 ExoPlayer）。
- Store 侧 `keepAliveEngaged` 去重；服务自身对重复 start 幂等（P1-4 设计）。

### 10.3 桥接与 attach 时机

Store 实现 `PlaybackSessionBridge`，`init` 末尾 `registry.attach(this)`（同步重放缓冲命令）。**本阶段无队列恢复窗口**（T-P1-10/11 未建），空队列上重放的 Play 是归约器已定义的 no-op，安全。`PlaybackSessionRegistry.kt:49-53` 的警告（提前注册会让重放 Play 落空队列）以"归约器空队列语义"消化；**T-P1-10/11 落地后必须将 attach 时机调整为"恢复完成时"**（代码 KDoc 已登记）。

## 11. 当前未完成的播放能力（如实登记）

| 能力 | 状态 | 归属/阻塞 |
|---|---|---|
| 在线曲目播放全链路 | **阻塞** | T-P1-05 音源解析器（`ResolveSongUrl` 效果无执行器）；本地曲目全链路真实可用 |
| 失败自动恢复执行 | 未接 | T-P1-06（依赖 T-P1-05 + errorCode 透传）；手动 `RetryCurrent→Prepare` 已可用（本地） |
| 音频焦点三模式运行时 | 未接 | T-P1-08（焦点事件源方案：Media3 内建 AudioFocusManager vs fork `AudioFocusEventListener` 获取路径需专门设计）；偏好意图已可归约 |
| 交叉淡化 | 未接 | T-P1-07（辅引擎 + 票据）；T-P1-02 完成条件中的 `abortCrossfade` 项因此遗留 |
| 睡眠定时执行 / 定时剩余流 | 未接 | T-P1-09 / T-P1-04；`SetSleepTimer` 已可归约 |
| 播放游标/队列持久化 | 未接 | T-P1-10 / T-P1-11（`FlushPersistence` 效果 TODO） |
| 预取票据 / 歌词生命周期 | 未接 | 数据层 / kugou 歌词模块 |
| UI 接入（迷你播放器/Dock/全屏） | 未接 | P3；当前 `PlayerScreen` 为占位 |
| 真机行为验证（起播/切歌/seek/倍速/音量/循环/焦点/杀进程续播） | **未执行** | 用户真机实测（无沙箱设备） |

## 12. 本阶段测试总览

| 套件 | 数量 | 类型 |
|---|---|---|
| `PlaybackReducerTest` | 140 | 纯 JUnit（无 Android）：42 意图全覆盖 + 12 事件 + 7 类竞态 + 空队列/边界/seek 合法性/循环随机/错误恢复/重复事件/过期事件 |
| `PlaybackStoreTest` | 33 | Robolectric 承载（TODO 效果走 `android.util.Log`，AGP mockable jar 下纯 JUnit 会抛 stub——探针实测后选用 Robolectric，编排断言不依赖 Robolectric 语义）：命令翻译表 12、attach/重放、意图→引擎序列、保活两路、位置管线、过期事件、释放、错误入口 4、Completed 语义 2、看门狗 6、StateFlow 可观察 |
| `ExoPlayerPlaybackEngineAdapterTest` | 26 | Robolectric 真 ExoPlayer：投射 8、控制可观察 5、监听去重 5、release 安全 2、位置流 3、主线程 1、初始态 1 |
| 既有回归（queue/state/session/gate/engine/model/core/theme…） | 343 | 全绿 |
| **合计** | **542** | 40 类，0 失败 / 0 错误 / 0 跳过 |

执行命令（真实输出见 phase-3-engine-validation.md）：
```
cd native && JAVA_HOME=~/dev-tools/jdk-17.0.20.1+1 ./gradlew :app:testDebugUnitTest      # 542 全绿（--rerun-tasks 实测）
cd native && JAVA_HOME=~/dev-tools/jdk-17.0.20.1+1 ./gradlew :app:assembleDebug :app:lintDebug  # BUILD SUCCESSFUL，lint 0 新增 error
```
