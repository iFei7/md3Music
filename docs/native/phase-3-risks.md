# 第三阶段 · 风险登记（phase-3-risks）

> 承接 decisions-and-risks.md R-01~R-15 与 phase-2-decisions.md D2-01~D2-10，仅登记第三阶段（T-P1-01/T-P1-02）范围内**新发现、未关闭或状态变化**的风险。
> 严重度：🔴 高（可致进程崩溃/功能静默失效）/ 🟡 中（行为偏差/需后续接线）/ 🟢 低（已缓解或有既定计划）。

---

## R3-01 🔴 media3fork 跨树耦合（承接 R-12，状态不变）

- **事实**：`:media3fork` srcDirs 零拷贝指向 `third_party/just_audio`，与 lite 活跃开发**共享同一份 fork 源码**；9 处产品级改动是 vivo 车载歌词、原子随身听、媒体卡下一首、后台通知刷新等差异化功能根基。任何"顺手修复"会同时改变 native 与 lite 两个消费方的编译产物。
- **本阶段动作**：fork 零改动；9/9 改动逐条核实仍在（phase-3-engine-validation.md §7）；门禁测试 `forkCustomizationsRemainAvailable` 全绿。
- **缓解**（D2-08 三道防线）：fork 标记完整性 grep 比对 / 门禁测试 / 上游拉取后复跑 542 单测 + 比对标记数。移除时机 = 播放核心稳定后评估，**不得以"能编译"作为行为一致证明**。
- **遗留**：T-P0-02 vendored 化（fork 纳入 native 仓自有副本）与 CI 指纹门禁尚未实施。

## R3-02 🔴 Rust JNI/FFI 与 panic=abort（承接 R-04/R-11，本阶段新增事实）

- **事实**：`panic = "abort"` + 全仓 0 处 `catch_unwind` → release 下 Rust handler 线程 panic = **整进程 abort，Kotlin 侧无法捕获**；Rust 导出旧包名死符号（`com.md3music.premium`），实际契约是 C FFI 四件套 + shim 三符号；**native 应用无生产启动方**（`KugouServerModule` 空骨架 TODO(P1)），当前 Rust 服务器由 lite Flutter 壳 dart:ffi 启动。
- **验证方案**（具体、可执行）：①对每个 JNI/shim 入口做入参模糊测试（空串/超长/非法 UTF-8/并发）；②关键路径加 Rust 侧 `catch_unwind` + 错误码返回（不改 ABI，属既有路径扩展）；③真机用 `adb shell am crash` 无关验证之外，专门构造已知 panic 路径（如 device_info 写满）观察进程行为；④考虑 `panic="unwind"` 或独立线程隔离的评估（改动需 Rust 工具链，沙箱不可用 → 登记为环境阻塞）。
- **纪律**：不通过捕获 Kotlin `Exception` 宣称可处理 Rust 进程级崩溃；不随意改 Rust ABI 或删 JNI 兼容代码。
- **本阶段改动**：零。Store 的 `ResolveSongUrl` 效果是未来经 `KugouServerGateway` 走 HTTP 数据面的挂点（不经 JNI）。

## R3-03 🔴 Android 7–9 两项已知缺陷未修复（承接 R-09/R-10，状态不变）

- **R1**：`MediaStoreScanner.kt:98` 用 `getColumnIndexOrThrow(RELATIVE_PATH)`（API 29+）无回退 → API 24–28 本地音乐扫描为空（回退链 `queryAll` 同样中招）。
- **R2**：`AudioPlaybackService.kt:621-623` `SuperLyricHelper.registerPublisher()` 无条件调用（minSdk 26），外层 `catch (Exception)` 捕不住 `Error` → API 24–25 可能 `NoClassDefFoundError` 崩溃。
- **纪律**（D2-09）：两项未修复前**不得宣称 Android 7–9 全面兼容**；本阶段所有测试跑在 JVM/Robolectric（sdk=32 模拟），无真机覆盖。验证矩阵 = Android 7.0/8.x/9 真机（依赖用户设备）。

## R3-04 🟡 在线音源阻塞及其下游效应（T-P1-05 交付后降级）

- **原始事实**：T-P1-05 音源解析器未建 → `ResolveSongUrl` 效果无执行器 → 在线曲目播放链路不打通；看门狗对在线曲触发会把 `isResolvingUrl` 置 true 且永不收敛。
- **2026-10-14 状态更新（T-P1-05 交付，见 phase-3b-source-resolver.md）**：解析器已落地（降级链/三分流/响度缓存/Store 回写环），`ResolveSongUrl` 有真实执行器，回写环自动清 `isResolvingUrl` 并重备——**不收敛问题解除**；看门狗 `RetryCurrent` 现走真实重备。在线曲目播放链路**代码层打通**（631 单测含全链路测试）。
- **遗留**：真机验证（起播/云盘/试听/弱网超时）；20028 设备重注册、20018 token 刷新、VIP `/song/url/new` 通道（无会话层，T-P2-07）；~~解析失败不自动跳下一首（T-P1-06 恢复链）~~（**T-P1-06 已交付**：解析失败 → `RecoveryOrchestrator` 自动跳下一首 + 退避恢复）；响度字段真机常缺（F-SRC-008，缓存常空属预期）。
- **纪律不变**（简报 §6/D2-02）：不虚构 URL；不绕过 `/audio/proxy` 403 与鉴权；播放缓存实现前必须验证（URL 可达性、Range 支持、容量/清理规则）。

## R3-05 ✅ 已关闭：errorCode 透传缺口（新 → T-P1-06 关闭）

- **原始事实**：适配器 `onError(message)` 仅带收敛文案，不透传 media3 `PlaybackException.errorCode`；Store 给 ErrorEventGate 传哨兵 `-1`（≠ lite 中断码 10000000，native 无该自定义码）。
- **后果**：切歌中断类错误暂无法与真实错误区分，只能靠「代次 + 粘性 loadCompleted」双条件近似；恢复链的错误分类（`classifyPlaybackRecoveryFailure` 读 HTTP/平台错误码）无法工作。
- **2026-10-14 关闭（T-P1-06 B1 交付）**：透传链路已补齐并测试覆盖——
  1. 新增错误载体 `com.gracemusic.player.model.PlaybackErrorInfo`（`message`/`errorCode`/`errorCodeName`/`httpStatusCode`/`origin`/`songId`）；
  2. `EngineListener.onError(info: PlaybackErrorInfo)`（**载体类型选型**，非 `onError(message, errorCode)` 形参扩展：Kotlin 接口默认参数要求实现方签名逐字一致，形参扩展会一次性打断全部实现且后续加字段再打断）；
  3. 适配器 `onPlayerError` 透传 `error.errorCode` / `error.errorCodeName`，并从 `cause` 链反射提取 `httpStatusCode`（`:app` 不引 media3-datasource，反射取不到即 null，不臆造）；
  4. `PlaybackEvent.EngineError(info)` 携带分类信息，`classifyPlaybackError` 为**纯函数**（无 IO/Android 依赖），`recoveryActionFor` 给出「8 类 → 恢复动作」映射；
  5. 中断码 `10000000` 归 `USER_CANCELED → IGNORE`，不再靠 `-1` 哨兵近似。
- **测试证据**：`ExoPlayerPlaybackEngineAdapterTest.onPlayerError_透传原始错误码与码名`、`onPlayerError_从cause链提取HTTP状态码`、`RecoveryOrchestratorTest.错误透传_错误码到达决策入口且中断码被忽略`、`错误分类与恢复动作映射`。
- **遗留**：真机下 media3 错误码分布需实测复核（弱网/失效链接/切歌）。

## R3-06 ✅ 已关闭：RetryPlayback 效果无生产者（新 → T-P1-06 关闭）

- **原始事实**：`PlaybackEffect.RetryPlayback(songId)` 已定义且执行器只记 TODO 日志，但**归约器与 Store 均不产生它**（手动恢复走 `RetryCurrent→Prepare`；看门狗走 `RetryCurrent`）。
- **2026-10-14 关闭（T-P1-06 B3，二择一取选型 ①）**：恢复链决策后统一派发 `PlaybackIntent.RetryCurrent` 意图（复用既有已验证路径 `RetryCurrent → ResolveSongUrl / Prepare → UpdateSong → 重备`），据此 **`PlaybackEffect.RetryPlayback` 已删除**（无生产者、语义与 `RetryCurrent` 重叠）。执行器分支、KDoc 与 `phase-3-playback-store.md` 效果清单同步更新。
- **测试证据**：`RecoveryOrchestratorTest` 全部重试类用例均经 `RetryCurrent` 驱动（`恢复_短暂网络故障后按退避重试成功` 等）。

## R3-07 🟡 看门狗最小间隔为 native 新增常量（新）

- **事实**：`STALL_REFRESH_MIN_INTERVAL_MS = 10s` 在 Dart 无对位常量（native 侧防循环叠加，取与 Dart 缓冲余量同量级）。其余 7 个常量全部可考（`player_provider.dart:411-447`）。
- **缓解**：KDoc 注明来源；真机验证换源频率后校准。

## R3-08 🟡 attach 时机与队列恢复窗口（新）

- **事实**：Store 在 `init` 末尾 `registry.attach(this)` 并同步重放缓冲命令；本阶段无队列恢复（T-P1-10/11 未建），空队列上重放的 Play 是归约器已定义 no-op（安全但无音量）。
- **风险**：`PendingCommandBuffer` 容量 4（溢出丢最旧）。冷启动窗口（Hilt + 未来 Room/Rust 就绪）内连按媒体键超过 4 次会丢命令。KDoc 称实测恢复数百毫秒，但 Store 真实恢复时长需实测。
- **缓解**：T-P1-10/11 落地时将 attach 调整为"恢复完成时"（代码 KDoc 已登记）；恢复窗口实测后复核容量。

## R3-09 🟢 保活两路驱动（新，已缓解）

- **事实**：意图路径（归约器效果）+ 事件路径（`onIsPlayingChanged` 对账）双路驱动保活，覆盖通知栏 PLAY_PAUSE 不经意图的路径。
- **残留**：Pause 意图后到引擎 isPlaying=false 事件到达前，状态 `isPlaying` 仍为 true（引擎权威未收敛）——此时若有事件路径对账会短暂 start（自纠）。Store 侧 `keepAliveEngaged` 去重 + 服务幂等已限制影响。真机验证时关注保活通知是否有多余闪现。

## R3-10 🟢 Store 测试的 Robolectric 承载偏差（新，已缓解）

- **事实**：TODO 效果调 `android.util.Log`，AGP mockable jar 下纯 JUnit 抛 stub 异常 → `PlaybackStoreTest` 以 Robolectric 承载（编排断言不依赖 Robolectric 语义：假引擎 + 虚拟时钟）。
- **缓解**：构建配置（unitTests.isReturnDefaultValues）不在本阶段允许修改清单；P2 可开启该选项回归纯 JUnit，或为 TODO 效果注入日志接口。

## R3-11 🟢 Store 首次注入线程契约（新，已缓解）

- **事实**：引擎 @Singleton @MainThread，Store 注入引擎——若 Store 首次被后台线程请求，引擎构建会踩 `verifyApplicationThread()`（`IllegalStateException: Player is accessed on the wrong thread`）。当前入口（UI/MediaSessionService/KeepAliveService/MediaButtonReceiver）均为主线程。
- **缓解**：Store 标注 `@MainThread`；未来若有后台入口（如同步/Worker），必须先 `withContext(Dispatchers.Main)` 或预热引擎。

## R3-12 🟢 originalPlaylist append 不对称（从 P1-5a 带入，待用户确认）

- **事实**：`PlaybackQueue.append` 不同步 `originalPlaylist`（lite 既有不对称）——随机播放追加歌曲后关闭随机会丢追加项。
- **状态**：`PlaybackQueue.kt:38-42` 自述保留 lite 行为并在 T45 登记待确认；本阶段 Store 接线未放大该问题。**待用户决定是否修正**（修正 = 偏离 Dart 逐值对齐，需同步两侧）。

## R3-13 🟡 真机验证矩阵未执行（新）

- **未验证项**：起播→切歌→seek→倍速→音量→循环/随机→睡眠定时全流程无崩溃（Android 7/9/12/14 四档）；拔耳机/来电/断蓝牙焦点三模式行为；杀进程后媒体键唤醒续播；息屏保活；DSP 真实解码音质。
- **入口**：CI run #11（`ab9b192`）已触发预构建，产物可下载至真机；第三阶段提交（本地）待用户确认后可推送触发新一轮预构建。

## 风险总览

| ID | 严重度 | 状态 | 归属 |
|---|---|---|---|
| R3-01 fork 跨树耦合 | 🔴 | 开放（三道防线运行中） | T-P0-02 vendored 化 |
| R3-02 Rust panic=abort | 🔴 | 开放（验证方案已定，工具链阻塞） | Rust 工具链可用后 |
| R3-03 Android 7–9 两缺陷 | 🔴 | 开放（未修复前不宣称兼容） | 本地音乐/歌词模块修复时 |
| R3-04 在线音源阻塞 + isResolvingUrl 不收敛 | 🟡 | **代码层解除**（T-P1-05 交付，真机待验） | T-P2-07 会话层 / T-P1-06 恢复链 |
| R3-05 errorCode 透传缺口 | ✅ | **已关闭**（T-P1-06 B1 交付，载体类型透传） | — |
| R3-06 RetryPlayback 无生产者 | ✅ | **已关闭**（T-P1-06 B3，选型①：派 `RetryCurrent`，效果已删） | — |
| R3-07 看门狗 10s 常量 | 🟡 | 开放（可校准） | 真机验证后 |
| R3-08 attach 时机/缓冲容量 | 🟡 | 开放（KDoc 已登记） | T-P1-10/11 |
| R3-09 保活两路驱动 | 🟢 | 已缓解 | 真机复核 |
| R3-10 测试承载偏差 | 🟢 | 已缓解 | P2 |
| R3-11 首次注入线程 | 🟢 | 已缓解 | — |
| R3-12 originalPlaylist 不对称 | 🟢 | 待用户确认 | 用户决策 |
| R3-13 真机验证矩阵 | 🟡 | 开放 | 用户真机实测 |
