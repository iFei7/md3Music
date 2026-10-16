# 第五阶段 · 音频焦点运行时（phase-5-audio-focus）

> 任务：**T-P1-08**（音频焦点运行时：三模式运行 + 忽略焦点开关 + becomingNoisy + 前后台信号）
> 交付提交：见本文件末尾「Git」节
> 关联矩阵项：F-FOC-001/002/003/004/005/006、F-SET-039/040
> 关联风险：**R4-01**（前后台语义被抹平）、**R4-02**（已于 T-P1-13 关闭）、R-4（网络恢复不自动续播）

---

## 1. 落地前现状审计（源码核实，均为真实行号）

| 事实 | 位置 | 结论 |
|---|---|---|
| 焦点决策纯函数已存在 | `player/gate/AudioFocusPolicy.kt`（`decideInterruptionAction`） | F-FOC-001 已完成；但它是 **audio_session interruptionEvent** 路径的对位，native 无该路径 |
| **fork 已暴露原始焦点事件** | `third_party/just_audio/android/src/main/java/androidx/media3/exoplayer/AudioFocusManager.java:167-185` | `addAudioFocusEventListener` / `removeAudioFocusEventListener`（进程级 static） |
| fork 已暴露忽略/保持播放标志 | 同文件 `:191-193`（`setForcedWillPauseWhenDucked`）、`:199-201`（`setIgnoreAudioFocus`）、`:208-210`（`setForceKeepPlaying`） | 三个进程级 static 开关 |
| fork 的跳过判定 | 同文件 `:213-226`（`shouldSkipFocusHandling`）、`:398-406`（`willPauseWhenDucked`） | `ignoreAudioFocus` 全跳；`forceKeepPlaying` 仅跳短暂中断；独占 `LOSS` 仍让路 |
| 原始事件**先于**内置处理派发 | 同文件 `:506-507`（`handlePlatformAudioFocusChange` 开头） | 宿主可据此覆盖 Media3 默认行为 |
| Media3 内置处理 | 同文件 `:521-546` | `GAIN → PLAY_WHEN_READY`；`LOSS → DO_NOT_PLAY + abandon`；`LOSS_TRANSIENT(_CAN_DUCK) → WAIT_FOR_CALLBACK 或 duck(0.2)` |
| 引擎焦点配置 | `player/engine/AudioEngineFactory.kt:104-106` | 主引擎 `setAudioAttributes(..., handleAudioFocus = true)`；辅引擎不下发属性（永不请求焦点） |
| 焦点意图已存在但**无状态位** | `state/PlaybackIntent.kt:217-232`；`store/PlaybackReducer.kt:219-226`（原 `persistOnly`） | 归约「只落盘不写状态」 |
| **无焦点运行时** | 全仓 grep 无 `AudioFocusController` | T-P1-08 的核心缺口 |
| `AppForegroundChanged` **无生产者** | `state/PlaybackIntent.kt:269`；`store/PlaybackReducer.kt:249`（原 `unchanged`） | 全仓无 `ProcessLifecycle` / `ActivityLifecycleCallbacks` |
| `AppForegroundChanged` 的唯一消费 | `store/PlaybackStore.kt` 原 `if (!backgrounded) recovery.onExternalRecoveryTrigger()` | 与 R-4 冲突（见 §5） |

### 1.1 与 Dart 的对位来源

| Dart | 位置 | native 对位 |
|---|---|---|
| `_handleMedia3FocusChange`（三模式运行时） | `lib/core/services/audio_service_io.dart:595-645` | `AudioFocusController.handleFocusChange` |
| `_syncNativeFocusFlags`（标志下发） | 同文件 `:541-558` | `AudioFocusController.syncNativeFlags` |
| `setIgnoreAudioFocus` / `setInterruptionMode` | 同文件 `:518-538` | `PlaybackIntent.SetIgnoreAudioFocus` / `SetAudioFocusInterruptionMode` |
| `_pausedByInterruption` 标志 | 同文件 `:668-671`（仅 `play()` 清） | `AudioFocusController.pausedByInterruption`（**收紧**，见 §4） |
| 焦点设置持久化键 | `lib/data/repositories/settings_repository.dart:611-646` | `settings_ignore_audio_focus` / `settings_audio_focus_interruption_mode` |
| `_isAppBackgrounded` | `lib/providers/player_provider.dart:352` | `PlaybackState.isAppBackgrounded` |

---

## 2. 交付内容

### 2.1 焦点事件源端口（新增）

**`player/gate/AudioFocusEventSource.kt`**
- `fun interface AudioFocusEventListener { fun onAudioFocusChanged(focusChange: Int) }` —— 原始 `AudioManager.AUDIOFOCUS_*` 值。
- `interface AudioFocusEventSource`：`addListener` / `removeListener` / `setIgnoreAudioFocus` / `setForceKeepPlaying` / `setForcedWillPauseWhenDucked`。
- `object NoOpAudioFocusEventSource`：测试/降级用空实现。

**`player/engine/Media3AudioFocusEventSource.kt`**（生产实现，`@Singleton`）
- 委托 fork 的四个 static 入口（逐条对位见其 KDoc 表）。
- **监听器适配**：fork 的 `AudioFocusManager.AudioFocusEventListener` 与本地端口是**两个类型**；fork 的 `add`/`remove` 依赖**同一实例**（`List.contains` / `List.remove`），故用 `ConcurrentHashMap` 缓存「端口监听器 → fork 适配器」映射。**若不缓存，注销会静默失败并留下永久静态监听（进程级泄漏）**。

### 2.2 运行时控制器（新增）

**`player/store/AudioFocusController.kt`**（`internal`）
- `attach()` / `detach()`（幂等）；`detach` 后迟到事件一律丢弃。
- `onPreferenceChanged(ignore, mode)`：更新内部态并重下发 fork 标志。
- `onUserTransportIntent()`：清「中断暂停」标志。
- `handleFocusChange(focusChange)`：三模式运行时（逐分支对位 Dart，见类 KDoc 表）。
- `interface AudioFocusHost { isPlaying(); pauseByInterruption(); resumeAfterInterruption() }`。

### 2.3 状态与意图

**`PlaybackState`** 新增两字段（契约演进，见 §3）：
- `ignoreAudioFocus: Boolean = false`
- `audioFocusInterruptionMode: AudioFocusInterruptionMode = KEEP_PLAYING`

**`PlaybackIntent.PauseByInterruption`**（新增词汇）：系统中断暂停。
- 归约结果与 `Pause` **逐字段相同**（`awaitingPlaybackProgress=false`、`manualRetryInFlight=false`，效果 `Pause` + `StopKeepAlive` + `PersistPlaybackCursor`）。
- 差异**只在 Store 的意图分类**：
  - **不**在 `isRecoveryCancellingIntent` → **不**清 `pendingFailure` / 不重置恢复预算；
  - **不**在 `isUserTransportIntent` → **不**清「中断暂停」标志（`GAIN` 才能恢复）。

**`PlaybackState.isAppBackgrounded`**（新增事实字段）。

### 2.4 Store 接线

| 位置 | 改动 |
|---|---|
| 构造器 | 新增 `audioFocusEventSource: AudioFocusEventSource = NoOpAudioFocusEventSource`、`appForegroundMonitor: AppForegroundMonitor = NoOpAppForegroundMonitor`（默认值使既有测试零改动） |
| `init` | `focusController.attach()` + 下发初始偏好；`appForegroundMonitor.start { dispatch(AppForegroundChanged(it)) }` |
| `dispatch(intent)` | ①`isUserTransportIntent` → `onUserTransportIntent()`；②焦点偏好意图后 → `onPreferenceChanged(...)` |
| `dispatch(event)` | **移除** `AppForegroundChanged → recovery.onExternalRecoveryTrigger()`（R-4 复核，见 §5） |
| `StoreAudioFocusHost`（新增 inner class） | `pauseByInterruption` → `dispatch(PauseByInterruption)`；`resumeAfterInterruption` → `dispatch(Resume)` |

### 2.5 前后台信号生产者（新增）

**`player/gate/AppForegroundMonitor.kt`**：端口 + `NoOpAppForegroundMonitor`。
**`player/engine/ProcessLifecycleAppForegroundMonitor.kt`**：`ProcessLifecycleOwner` 实现。
- `onStart → backgrounded=false`；`onStop → backgrounded=true`。
- **为什么是 ProcessLifecycleOwner**：它是 AndroidX 官方的**应用级**聚合信号，且对 `onStop` 加了约 700ms 延迟以吸收旋转/多窗口的瞬时 stop-start 抖动——正是「不得在每个页面各自维护一份前后台状态」所要求的统一信号源。用 `ActivityLifecycleCallbacks` 自行计数会在配置变化时误报，且无法正确处理多 Activity / 分屏。
- **新增依赖**：`androidx.lifecycle:lifecycle-process`（版本 `lifecycle = 2.10.0`，与既有 lifecycle 同版本；Apache-2.0）。用途：`ProcessLifecycleOwner`（`lifecycle-runtime` 不含）。

### 2.6 DI

`di/PlayerModule.kt` 新增 `provideAudioFocusEventSource()`（绑 fork 实现）与 `provideAppForegroundMonitor()`（绑 ProcessLifecycle 实现）。

### 2.7 文件清单

**新增生产文件（5）**
- `player/gate/AudioFocusEventSource.kt`
- `player/engine/Media3AudioFocusEventSource.kt`
- `player/store/AudioFocusController.kt`
- `player/gate/AppForegroundMonitor.kt`
- `player/engine/ProcessLifecycleAppForegroundMonitor.kt`

**修改生产文件（7）**
- `player/state/PlaybackState.kt`（+2 字段、+1 事实字段）
- `player/state/PlaybackIntent.kt`（+`PauseByInterruption`）
- `player/store/PlaybackReducer.kt`（焦点偏好写字段；`PauseByInterruption`；`AppForegroundChanged` 写字段）
- `player/store/PlaybackStore.kt`（控制器接线、宿主、R-4 复核）
- `player/store/RecoveryOrchestrator.kt`（KDoc：`onExternalRecoveryTrigger` 当前无调用方）
- `di/PlayerModule.kt`（+2 绑定）
- `native/gradle/libs.versions.toml` + `native/app/build.gradle.kts`（+`lifecycle-process`）

**新增测试（2）**
- `player/store/AudioFocusControllerTest.kt`（22 条）
- `player/store/AudioFocusStoreTest.kt`（14 条）

**追加测试（1）**
- `player/store/PlaybackReducerTest.kt`（+7 条，含 3 条契约演进改写）

---

## 3. 契约演进登记（必须显式说明，非「放宽断言」）

| 变更 | 原契约 | 新契约 | 理由 |
|---|---|---|---|
| `SetIgnoreAudioFocus` 归约 | 只落盘不写状态 | **写 `PlaybackState.ignoreAudioFocus`** + 落盘 | 设置页与 `AudioFocusController` 需要权威读值；`PlaybackState` 是播放域唯一状态快照 |
| `SetAudioFocusInterruptionMode` 归约 | 只落盘不写状态 | **写 `PlaybackState.audioFocusInterruptionMode`** + 落盘 | 同上 |
| `SetRestoreMemoryEnabled` 归约 | 只落盘不写状态 | **写 `PlaybackState.restoreMemoryEnabled`** + 落盘（T-P1-10） | 冷启动恢复判定需要读它 |
| `AppForegroundChanged` 归约 | `unchanged`（无状态可写） | **写 `PlaybackState.isAppBackgrounded`** | 生产者接入后需要一个权威可见性来源 |
| `AppForegroundChanged` 消费 | `!backgrounded → onExternalRecoveryTrigger()` | **无播放动作**（R-4 复核） | 见 §5 |
| 同值守卫 | 无 | 三者均加「同值 → no-op」 | 避免重复落盘与无意义状态发射 |

既有测试断言同步改写（3 处），**未删除任何用例、未放宽任何断言**。

---

## 4. 相对 Dart 的收紧（登记）

1. **`pausedByInterruption` 清除点扩大**：Dart 只在 `play()` 清（`audio_service_io.dart:668-671`），用户 `pause()` 不清——于是「中断暂停 → 用户暂停 → `GAIN`」会被**错误恢复**。native 把清位点扩到**全部用户传输意图**（起播/暂停/切歌/重试/seek/停止/清空队列），堵住该路径。这是验收项「用户主动暂停不被自动播放」的实现基础。
2. **不调用 `abortCrossfade()`**：Dart 在 `keepPlaying` 的 `LOSS` 分支与 `pauseAndResume` 的非 `GAIN` 分支都先调 `abortCrossfade()`。native 的交叉淡化（T-P1-07）**尚未落地**，故暂不调用。**登记**：T-P1-07 落地时**必须**在 `handleFocusChange` 补 `abortCrossfade()`，否则淡化中收到焦点事件会留下未收敛的 incoming 播放器（Dart 注释记录过该路径会造成「切歌时音量突然变大」）。

---

## 5. R-4 复核结论（T-P1-08 B4 的硬性要求）

### 5.1 复核对象
第四阶段为「回到前台尝试重试」保留了：
```kotlin
is PlaybackEvent.AppForegroundChanged ->
    if (!event.backgrounded) recovery.onExternalRecoveryTrigger()
```
R-4（产品决策 4）：**网络恢复后不自动恢复播放，需等待用户手动操作**。

### 5.2 复核发现
该连线构成一条**间接**的自动续播路径：
```
在线播放失败（可重试分类）→ pendingFailure 非空 → 退避排期
  → 网络恢复（仅探测值变化，不触发任何动作）
  → 用户切回 App（ProcessLifecycleOwner.onStart）
  → onExternalRecoveryTrigger() → attemptRecovery()
  → 分类门 isNetworkAvailable() 此时已为 true → 通过
  → 消耗预算 → 派 RetryCurrent → 自动播放
```
即：**用户没有做任何播放操作，播放自己恢复了**——与产品决策 4 冲突。

### 5.3 结论与处置
**移除该连线**。`AppForegroundChanged` 现在只写事实字段 `PlaybackState.isAppBackgrounded`。

`RecoveryOrchestrator.onExternalRecoveryTrigger()` **能力保留**（不删除），但**当前生产代码无调用方**——恢复重试只由 `scheduleBackoff` 的退避定时器驱动。KDoc 已收敛并注明：调用方**必须**确保它不会被「网络由离线转在线」或「应用回到前台」这两类事实驱动。

### 5.4 为什么仍然接入生产者
1. R4-01 明确登记「恢复链前后台语义被抹平」，且第四阶段报告把「接入 `AppForegroundChanged` 生产者」列为 T-P1-08 的前置条件；
2. `isAppBackgrounded` 是 UI（诊断/刷新策略）与后续任务（T-P1-09 睡眠定时到点执行可能需前台判据）的权威来源，避免它们各自去问 `ProcessLifecycleOwner`；
3. 事件**低频**（仅真正的前后台切换），不构成「无必要地向业务层发射高频生命周期事件」。

### 5.5 锁定测试
- `AudioFocusStoreTest.回前台_只写事实字段_不触发任何播放或重试`：回前台后推进 300s（远超 30/60/120s 退避档）→ 引擎调用序列**零新增**。
- `AudioFocusStoreTest.切后台_写后台事实字段` / `前后台事件_同值不重复写状态`。
- `PlaybackReducerTest.AppForegroundChanged_写后台事实字段且不产生效果`（断言 `effects.isEmpty()`）。

---

## 6. 与 Media3 内置机制的分工（验收项：不存在重复控制）

**本控制器不注册任何自己的 `AudioManager.OnAudioFocusChangeListener`。** 它消费 fork 转发的原始事件，并通过三个开关**改写** Media3 内置处理：

| 模式 | `setIgnoreAudioFocus` | `setForceKeepPlaying` | `setForcedWillPauseWhenDucked` | 内置处理 |
|---|---|---|---|---|
| `KEEP_PLAYING` | false | **true** | true | 短暂中断全跳过；独占 `LOSS` 仍 `DO_NOT_PLAY`（宿主再补一次显式暂停以同步状态） |
| `PAUSE_AND_RESUME` | false | false | true | 系统派发 `LOSS_TRANSIENT` 事件而非静默 duck；内置 `WAIT_FOR_CALLBACK` 暂停、`GAIN` 恢复（宿主同步状态 + 精确恢复） |
| `DUCK_AND_RESTORE` | false | false | **false** | 保留系统级自动 duck（0.2 倍）与 `GAIN` 自动恢复；**宿主不干预**（对位 Dart 该模式无分支） |
| 忽略模式 | **true** | false | true | 全跳过（含独占 `LOSS`） |

**验收项「系统焦点中断不被 `RecoveryOrchestrator` 当成解析故障」**：由**结构**保证——控制器只派 `PauseByInterruption`，从不投递 `PlaybackEvent.EngineError`，因此根本不进入失败分类。测试 `系统中断暂停_不触发任何重试动作_即使推进退避窗口` + `PauseByInterruption_不产生任何错误效果` 锁定。

---

## 7. 测试

### 7.1 `AudioFocusControllerTest`（22 条）
attach/detach 生命周期与幂等、迟到事件丢弃、未 attach 不处理、三模式 × 四种中断类型决策表、`KEEP_PLAYING` 独占 `LOSS` 让路、`PAUSE_AND_RESUME` 记/恢复/未播放不动作/未曾中断不恢复、`DUCK_AND_RESTORE` 不干预、忽略模式全不响应、五组 fork 标志下发断言、偏好变更重下发、detach 后不下发。

### 7.2 `AudioFocusStoreTest`（14 条）
系统中断暂停 → 引擎 `pause` + 无错误 + 清等待标志；推进 300s 无重试；`KEEP_PLAYING` 短暂中断不暂停 / 独占 `LOSS` 让路；`DUCK_AND_RESTORE` 不改变播放态；忽略模式不暂停；中断后 `GAIN` 自动恢复；**用户主动暂停后 `GAIN` 不播放**；用户切歌后 `GAIN` 不恢复旧曲；未曾中断 `GAIN` 不恢复；回前台只写事实字段不触发动作；切后台写字段；同值不重复写；焦点偏好意图写状态 + 下发标志；启动即装配。

### 7.3 `PlaybackReducerTest` 追加（7 条）
`PauseByInterruption` 与 `Pause` 逐字段一致 / 不产生错误效果；两个焦点偏好意图写内存并落盘 + 同值无操作；`AppForegroundChanged` 写字段且无效果 + 同值无操作。

---

## 8. 真机验证限制（**不得宣称已通过**）

沙箱无 Android 设备/模拟器。以下**全部未执行**，任何「真机可用」声明均不成立：

- 来电 / 导航 / 语音助手中断的三模式实际表现；
- 拔耳机 / 蓝牙断开的 `becomingNoisy` 自动暂停（F-FOC-006 既有交付，本阶段未复测）；
- `ProcessLifecycleOwner` 在 OEM ROM（MIUI/EMUI 等）上的 700ms 延迟是否被系统省电策略放大；
- Android 7–9（minSdk 24）上的 `AudioFocusRequestCompat` 路径；
- Media3 内置 `WAIT_FOR_CALLBACK` / duck 与宿主暂停的**实际**时序是否产生可感知的重复动作。

---

## 9. 遗留风险

| ID | 描述 | 严重度 | 归属 |
|---|---|---|---|
| R5-10 | `abortCrossfade()` 未接入焦点路径 | 🟡 | **T-P1-07 落地时必须补**（见 §4.2） |
| R5-11 | `onExternalRecoveryTrigger()` 无调用方 | 🟢 | 后续若接入必须重新评估 R-4 |
| R5-12 | 真机焦点行为全未验证（见 §8） | 🔴 | 用户实测 |
| R5-13 | `ProcessLifecycleOwner` 的 700ms `onStop` 延迟导致「快速切后台又回来」不产生事件 | 🟢 | 官方行为；对播放策略无影响（本信号不驱动播放） |
| R5-14 | Media3 内置 `GAIN → PLAY_WHEN_READY` 无法区分「用户中断期间主动暂停」 | 🟡 | 上游行为；native 已通过 `pausedByInterruption` 覆盖宿主侧，但内置路径仍可能恢复（Dart 同） |
