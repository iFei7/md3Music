# 第三阶段 · 功能闸门清单与接线审计

> 依据：第一阶段审计记录（10 道闸门口径）+ 第三阶段源码逐项核实（`player/gate/` 实为 **11 个文件**）。
> 结论口径：**逻辑全部 1:1 移植且 68 个单测覆盖；本阶段（T-P1-02）运行时接入 5 个，6 个登记未接及原因**。USB 独占输出确认无残留。

---

## 0. 口径澄清

| 说法 | 事实 | 证据 |
|---|---|---|
| "10 道功能闸门" | 矩阵 F-GATE-001~010 的 10 项；`gate/` 目录实际 **11 个文件**——第 11 个是 `AudioFocusPolicy.kt`（三模式焦点决策，矩阵归 F-FOC 域） | `plans/audit-index-2026-10-13.md:73`、矩阵 §5.24、`native-architecture.md:301-314` 三处互证清单为 10 项；目录 ls 为 11 文件 |
| "Rust 68 个单元测试" | **无此记录**。68 = 闸门单测数（P1-1 `6875a0c`）；Rust 实测 **65 个 `#[test]`**（`cargo test` 沙箱不可执行，见 phase-3-engine-validation.md §5） | `native-architecture.md:675`、`plans/parts/d2b-features-nonui.md:12`；Rust grep 计数 |
| 闸门逻辑正确性 | native 与 Dart **逐值一致**（含边界：严格大于基线、12s 超时严格大于、`floor<=0` 不 arm） | 逐文件全文比对 + 68 单测 |

---

## 1. 逐项核查与接线状态

### 1.1 本阶段已接线（5 个）

| # | 闸门 | 位置 | 输入 → 通过 / 拒绝 | 副作用 | 测试 | 接线位置（T-P1-02） |
|---|---|---|---|---|---|---|
| G1 | **PlaybackRequestGate** | `gate/PlaybackRequestGate.kt:16-27` | 无入参，内部代次自增；`isCurrent` 仅最新代为真 | 无（纯内存计数器） | `PlaybackRequestGateTest` 3 | `PlaybackStore.kt:640-657`：播放族 12 意图派发前 `issue()`；仅 `Stop` 后 `invalidate()`。**代次主轴**——进度门/错误门/恢复门的钥匙 |
| G2 | **PlaybackProgressGate** | `gate/PlaybackProgressGate.kt:20-47` | `begin(request, baseline)` 登记；`observe` 要求 request 匹配 + 未上报 + 位置**严格大于** baseline → true 一次 | 无（纯内存） | `PlaybackProgressGateTest` 4 | `PlaybackStore.kt:480-498`：位置采样 observe 首真 → `PlaybackProgressConfirmed` + 快照基准刷新；Prepare/Play 效果处 `begin(gen, state.position)` |
| G7 | **PositionRewindGate** | `gate/PositionRewindGate.kt:29-84` | `arm(floor, now)`（floor≤0 不开启）；开启中 + 采样 < floor + 未超时 → 抑制；12s 超时自动 disarm | 无（纯内存 + 可注入时钟） | `PositionRewindGateTest` 7 | `PlaybackStore.kt:470-491`：采样**前置**抑制（被抑制的整条丢弃——不进 position 流、不进进度门，进度条不闪回）；Prepare/Play 时 `arm(floor=baseline)`；首真确认后 disarm |
| G3 | **PlaybackErrorEventGate** | `gate/PlaybackErrorEventGate.kt:8-29` | `shouldHandlePlaybackErrorEvent(errorCode, isCurrentRequest, loadCompleted)`：中断码（10000000）→ false；否则要求双真 | 无（纯函数） | `PlaybackErrorEventGateTest` 3 | `PlaybackStore.kt:437-451`：`onError` 入口过滤。**errorCode 传哨兵 -1**（适配器不透传 media3 错误码，native 无 lite 自定义中断码——登记 T-P1-03/T-P1-06）；`loadCompleted` 用粘性判据（见下） |
| G6 | **PlaybackStallPolicy** | `gate/PlaybackStallPolicy.kt:28-45` | `classifyCdnStallWindow(advanced, elapsed, bufferedHeadroom, minimumBufferedHeadroom, minimumPlaybackRate)`：速率达标→SUFFICIENT；缓冲余量>下限→WAIT；否则→REFRESH_SOURCE | 无（纯函数） | `PlaybackStallPolicyTest` 5 | `PlaybackStore.kt:523-620`：2s ticker 看门狗（常量全部可考：`_stallMinPositionSec=45`/`_rateCheckInterval=2s`/`_minPlaybackRate=0.5`/`_minBufferedHeadroomForStallWait=10s`/`_stallMaxRetries=3`/`_rateCheckStartupGrace=15s`/`_urlLoadGuardWindow=3s`，Dart `player_provider.dart:411-447` 镜像）；REFRESH_SOURCE → `dispatch(RetryCurrent)`；native 侧叠加最小间隔 10s（Dart 无对应常量，KDoc 注明） |

**loadCompleted 粘性判据**（ErrorEventGate 的 native 适配，`PlaybackStore.kt:200-213` KDoc）：判据为「自上次 invalidate 以来有过 Prepare/Play 效果执行」，而非「当前代次已发出过」。原因：①native 的 seek 不触发重新装载（同一媒体项 `engine.seekTo`），字面判据会压制 seek 后的中游错误（Dart seek 不触碰请求闸门，同类错误照常上浮，`player_provider.dart:4208-4228`）；②native 无 Dart 的 setUrl Future 通道，装载阶段错误只能经事件通道可见，「已装载」只能用「引擎收到过 Prepare/Play」近似。

**看门狗挂 ticker 而非位置管线的结构修正**（`PlaybackStore.kt:523`）：StateFlow **合并相等值**——位置冻结（CDN 卡死的典型形态）时采集器不再触发，挂在采样通道上的看门狗永远等不到第二次评估。ticker 直接读 `engine.positionFlow.value` 当前值，等价 Dart 挂在 positionStream tick 上的语义。

### 1.2 本阶段未接线（6 个，逐项登记原因）

| # | 闸门 | 位置 | 未接原因 | 归属 |
|---|---|---|---|---|
| G4/G5 | **PlaybackRecoveryBudget** + **PlaybackRecoveryFlight** | `gate/PlaybackRecoveryBudget.kt:131-160`、`gate/PlaybackRecoveryFlight.kt:20-50` | 恢复**执行**路径依赖音源解析器（T-P1-05）+ errorCode 透传缺口；Dart 链 B 顺序已核实（先 `classifyPlaybackRecoveryFailure` → `budget.tryConsume` → `flight.tryStart` → 重解析 → 成功 `budget.reset` / 后台 `nextDelay` + `flight.sequence` 快照 → finally `releaseIfOwned`）。手动恢复已由 `RetryCurrent→Prepare` 覆盖（本地曲目真实可用） | **T-P1-06** |
| — | **AudioFocusPolicy** | `gate/AudioFocusPolicy.kt:79-153`（三模式 + `DUCK_VOLUME_RATIO=0.5`） | 纯函数可接，但**焦点事件源与 Dart 不同构**：lite 靠 fork 转发的 `audioFocusChangeStream`（`audio_service_io.dart:563-565`，且其运行态实为 `_syncNativeFocusFlags` 手写语义，未调用 `decideInterruptionAction`）；native 是 Media3 内建 `AudioFocusManager`（`AudioEngineFactory.kt:92-96` `handleAudioFocus=true`），fork 改动 #1 暴露的 `AudioFocusEventListener` 获取路径需专门设计。**为避免留"意图有字段、归约器空转"的半接线状态，整体推后**；偏好意图（`SetIgnoreAudioFocus`/`SetAudioFocusInterruptionMode`）已可归约（发 `PersistPreference`） | **T-P1-08** |
| G9 | **PlaylistPrefetchTicket** | `gate/PlaylistPrefetchTicket.kt:17-43` | 依赖三项目前不存在的基础设施：音质设置 DataStore（`PlayerModule.kt:50-51` TODO(P1) 自认待设置层）、`userId` 会话态（Kugou 侧）、`UpdateSong` 回写路径的归约器。提前接只能接到空转的 canCommit | 数据层就绪后 |
| G10 | **CrossfadePreparationTicket** | `gate/CrossfadePreparationTicket.kt:17-46` | 依赖交叉淡化模块（辅引擎创建、`_prepareCrossfade` 等价物）；native DI 只为辅引擎留了工厂入口，整条淡化链是后续主题 | **T-P1-07** |
| G8 | **LyricRequestLifecycle** | `gate/LyricRequestLifecycle.kt`（去重 + 负缓存 + 退避三件套） | 归 kugou 歌词业务模块（lite 挂 `KugouProvider` + 桌面歌词服务复用）；native `kugou/` 目前只有 server 网关三件套，无 provider 等价物 | kugou 歌词模块 |

### 1.3 接线链（Dart 调用点还原，native 保持同构）

```
链 A 代次主轴：RequestGate.issue() ──┬→ ProgressGate.begin(request, baseline)   （同点注册，共享代次）
                                    ├→ PositionRewindGate.arm(floor=baseline)  （同点注册，共享基线）
                                    ├→ ErrorEventGate(isCurrentRequest=…)       （错误入口挂代次）
                                    └→ RecoveryFlight.isCurrent(token)          （T-P1-06）
链 C 位置通道：采样 → RewindGate.shouldSuppress（抑制则根本不到进度门）→ ProgressGate.observe → 首真清 awaiting
链 B 恢复链：Budget.tryConsume → Flight.tryStart → … → finally releaseIfOwned（严格串行，T-P1-06）
```

**结论：11 个闸门不是 11 次独立接线，而是 1 个代次主轴 + 挂在其上的消费者。** 本阶段完成主轴 + 位置链 + 错误入口 + 看门狗；恢复链与票据类按模块成熟度后续接入。挑单个闸门先接会造成代次空间分裂——已避免。

## 2. USB 独占输出核查

**native 侧无 USB 闸门残留、无任何 USB 代码路径。** 全仓 grep（大小写不敏感）"usb" 仅 2 处注释命中（`AudioEngineFactory.kt:36` 说明 `NormalizationGainAudioSink` 因 `62d8b2f` 整链下线 USB 而判死代码不移植；`ViperMasterChainTest.java:56` 测试注释）。无 `UsbManager`/`setPreferredDevice`/独占模式 API 调用。按 D2-01（USB 永久排除），**不创建新闸门、不建占位实现**。

## 3. 与 lite 的语义差异摘要（影响接线的部分）

1. **AudioFocusPolicy 在 lite 也未接线**：lite 的中断入口 `_handleMedia3FocusChange`（`audio_service_io.dart:585-635`）手写 if 分支，**未调用** `decideInterruptionAction`——纯函数是文档化契约 + 单测对象。native 照搬该函数不等于照搬行为，故焦点整体推后（§1.2）。
2. **进度通道来源不同**：lite 靠 just_audio fork 的 `ObserverRenderer` 旁路广播（~200ms，P1-3 已决议**不移植**）；native 用适配器 200ms 采样流 + 进度闸门——采样源是本阶段新建的，lite 无对位物。
3. **恢复链触发条件差异**：lite 的自动重试有 `_isAppBackgrounded` 门（仅后台重试，`player_provider.dart:1163/1179`）；native `classifyPlaybackRecoveryFailure` 签名不带前后台参数，前后台判定需 Store 外挂（`PlaybackEvent.AppForegroundChanged` 词汇已在，归约层 no-op）——T-P1-06 接线时落地。
4. **RequestGate 的 pause 防抖细分**：lite 在 pause 防抖里对 RequestGate 有 6 处连续 isCurrent 校验（`player_provider.dart:3934-3982`）；native 暂停事务语义随 Store 暂停归约器细化时再对齐（本阶段 `Pause` 不 invalidate 代次——Dart `pause()` 也 invalidate（`:3921`），此处为已登记差异：native 的 isPlaying 由引擎事件收敛，暂停不清代次可使停机后的迟到错误被 `isCurrent` 正确拒绝）。

## 4. 测试与遗留

- 68 个闸门单测全绿（11 个测试类）；Store 侧新增接线断言 33 个（`PlaybackStoreTest`，含看门狗 6 例）。
- 遗留：恢复链（G4/G5）与焦点（AudioFocusPolicy）的运行时联调；票据类（G9/G10）与歌词（G8）的模块接入。详见 phase-3-risks.md。
