# 第四阶段 · 并发与高频通道审计（phase-4-concurrency-audit）

> 本报告记录第四阶段 **T-P1-04 高频双通道与定时剩余流** 的只读审计结论、最终实现与偏离登记。
> 审计基线：分支 `native`，开工前 HEAD `a0656b6`；开工前单测 **656 / 0 失败 / 0 错误 / 0 跳过**（`--rerun-tasks` 实测）。
> **总原则**：语义一律以 Dart 原始实现（`lib/providers/player_provider.dart`）与路线图为准；与任务措辞冲突处一律登记，不擅自设计新产品行为。

---

## 1. T-P1-04 的真实业务语义（审计确认）

### 1.1 「双通道」在 Dart 里指什么

Dart 的 `PlayerProvider` 继承 `ChangeNotifier`，**只有全量通知一种粒度**：任何 `notifyListeners()` 都会重建所有 `watch<PlayerProvider>()` 的页面与列表项。位置流每 ~200ms 触发一次，若走全量通知会导致整页抖动。为此 Dart 另开两条**独立** `ValueNotifier`：

| 通道 | Dart 声明 | 生产者 | 消费者 | 数据类型 | 频率 |
|---|---|---|---|---|---|
| 位置 | `positionNotifier`（`:537`） | `_updatePosition(value)`（`:685-696`），由 `positionStream` 采样驱动 | 进度条 / 进度环 / 歌词 | `Duration` | ~200ms |
| 定时剩余 | `sleepTimerRemainingNotifier`（`:742-743`） | `_sleepTimerTicker`（每秒 `Timer.periodic`），写点 `:5300-5315` | 睡眠药丸倒计时 | `Duration?` | 1s |

两者共同点：**只通知自己，不触发 `notifyListeners()`**（`:684` 注释、`:5309-5311` 注释）。低频快照（`_position` / `_sleepTimerEndTime`）仍随离散事件（切歌/暂停/seek）全量通知。

### 1.2 高频事件清单（审计枚举）

| 高频/并发事件 | 来源 | native 现状 |
|---|---|---|
| 播放进度采样 | 引擎位置流（~200ms） | 已有 `PlaybackStore.position: StateFlow<Duration>`（经 `PositionRewindGate` 抑制假回退） |
| 睡眠定时倒计时 | 每秒 ticker | **本次新增**（`sleepTimerRemaining: StateFlow<Duration?>`） |
| 队列更新 / 切歌确认 | 引擎 `onMediaItemTransition`（按 mediaId 身份） | 已有，归约器按身份对账丢弃迟到 transition |
| 播放状态变化 | 引擎 `STATE_*` | 已有 |
| 音源解析回调 | `SongUrlResolver.resolve`（异步） | 已有，经代次 + 曲目身份判定归属 |
| 引擎错误回调 | `onPlayerError` | 已有，本次补齐 errorCode 透传（见 phase-4-recovery.md） |

### 1.3 「定时剩余流」的真实语义（**不是** T-P1-09）

- 对应路线图条目 = **T-P1-04**（`docs/implementation-roadmap.md` §T-P1-04 标题「高频双通道 StateFlow（位置流 / 定时剩余流）」，输出 `PlaybackStore.kt`（位置/定时流））。
- 语义 = **睡眠定时倒计时的剩余时间通道**（每秒走字），**不是**倒计时执行、不是剩余播放时间、不是通用定时采样。
- 与 **T-P1-09**（睡眠定时执行 + 「播完当前曲」）的关系：**共用同一底层机制**（Dart 的 `_sleepTimerTicker` 既写 notifier 又在到点暂停，`:5300-5315`），故允许共享可复用内部组件；但**产品语义与测试保持独立**——T-P1-04 只交付「通道 + 定时器生命周期」，到点执行（暂停 / `SleepTimerMode` 迁移 / `stopAfterTimerEnds`）仍属 T-P1-09，本阶段**未实现**。

### 1.4 既有闸门对去重 / 回退 / 过期 / 抑制的覆盖

| 闸门 | 职责 | 归属 |
|---|---|---|
| `PlaybackRequestGate` | latest-wins 代次：旧请求不得覆盖新播放请求 | 已接线（T-P1-02） |
| `PositionRewindGate` | 抑制换源装载期的假回退采样（整条丢弃） | 已接线（T-P1-02） |
| `PlaybackProgressGate` | 只认本次请求基线之后的位置增长（同一请求只上报一次） | 已接线（T-P1-02） |
| `PlaybackErrorEventGate` | 过期请求 / 装载前错误 / 中断码（10000000）过滤 | 已接线（T-P1-02） |
| `PlaybackStallPolicy` | CDN 慢速窗口判定（看门狗 ticker 独立协程） | 已接线（T-P1-02） |

审计结论：**去重、回退抑制、过期事件、重复错误抑制均已有负责方，本阶段不重复实现**。

### 1.5 已存在的定时器 / ticker / 节流实现（审计）

- `PlaybackStore.runCdnStallWatchdog`（2s 周期协程，独立于位置通道——因 `StateFlow` 合并相等值）。
- 低频快照节流 `SNAPSHOT_REFRESH_INTERVAL_MS = 1000L`。
- 引擎适配器 `syncPositionSampling`（200ms 采样，暂停即停）。
- **无** `conflate` / `debounce` / `collectLatest` 使用。

---

## 2. 最终实现

### 2.1 三条通道分层（`PlaybackStore.kt`）

| 通道 | 生产者 | 类型 | 频率 |
|---|---|---|---|
| `state`（低频快照） | 归约器（唯一写路径） | `PlaybackState` | 离散事件 + 1s 节流 |
| `position` | `onPositionSample`（引擎采集，已有） | `Duration` | ~200ms |
| `sleepTimerRemaining` | `runSleepTimerTicker`（本次新增） | `Duration?` | 1s |

新增 API：

```kotlin
val sleepTimerRemaining: StateFlow<Duration?>   // PlaybackStore.kt:241；null = 无进行中的倒计时
```

**单一权威入口**：ticker **只写高频通道**，从不写 `PlaybackState`；`state.sleepTimerRemaining` 仍是归约器写出的低频快照。`PlaybackReducer.setSleepTimer`（`PlaybackReducer.kt:810-816`）的 KDoc 已预先约定「倒计时每秒的走字由 Store 的定时器写 `sleepTimerRemaining`」，实现与该约定一致。

### 2.2 定时任务生命周期规则（触发点）

| 事件 | 动作 | 代码 |
|---|---|---|
| `dispatch(SetSleepTimer(d != null))` | 取消旧 Job → 通道立即写满额 `d` → `scope.launch` 启新 ticker | `reconcileSleepTimerTicker`（`:703-717`） |
| `dispatch(SetSleepTimer(null))` | 取消 Job → 通道写 `null` | 同上 |
| 每秒 tick | 剩余 = `deadlineMs - clock()`；`> 0` 写剩余 | `runSleepTimerTicker`（`:733-748`） |
| 到点（剩余 ≤ 0） | 通道写 `null` + 自停；**不暂停、不迁移 mode**（`TODO T-P1-09` 日志） | 同上 |
| 作用域取消（Service 销毁 / 进程拆卸） | Job 随之取消；`invokeOnCompletion` 按身份清引用 | `:717` |
| **切歌 / `Stop` / 暂停恢复** | **不取消**（墙钟倒计时，Dart `Timer.periodic` 同） | 见偏离 1 |

常量：`SLEEP_TIMER_TICK_INTERVAL_MS = 1_000L`（`:981`）。

### 2.3 并发、取消与过期事件的处理方式

- **线程模型**：`PlaybackStore` 为 `@MainThread` 单例、**不用 Mutex**（加锁会掩盖「从后台线程派发」的模型错误）；ticker 绑定 `@StoreScope`（生产 = `Dispatchers.Main.immediate`），与引擎调用同线程，写入与状态读取无锁。
- **取消语义**：`Job` 自身即身份——重设 = 「取消旧 Job → 启新 Job」，**未引入第二套代次体系**；播放请求归属仍复用 `PlaybackRequestGate` / `activeRequestGen`。
- **迟到事件**：取消后的协程不再有任何写入（`delay` 协作式取消）；引擎释放后回调全部丢弃（适配器 `released` 守卫）。
- **不合并必要事件**：**未使用** `conflate` / `debounce` / `collectLatest`。位置流逐样本转发（由 `PositionRewindGate` 决定丢弃与否）；`EngineError` / `EnginePlaybackCompleted` / `EngineMediaItemTransition` 仍走归约器唯一路径，高频节流不影响其完整性（测试 `高频节流_错误事件仍完整到达归约器`、`高频节流_播放结束与队列切换事件仍完整到达归约器`）。
- **无界资源**：无 `Channel`、无无界队列；两个 ticker（睡眠定时 / CDN 看门狗）均为可取消的 `while (isActive) { delay(...) }` 协程。
- **不阻塞主线程**：高频路径只做常量算术与 `MutableStateFlow` 赋值，无 I/O、无 JSON 解析、无整状态重建。

---

## 3. 测试覆盖（`HighFrequencyChannelTest.kt`，17 条）

| 场景 | 测试名 |
|---|---|
| 高频进度更新 | `高频位置_低频快照发射次数不随采样率线性增长`、`高频位置_位置流末值即最新采样且低频快照不被高频覆盖` |
| 两个并发操作先后顺序 | `并发解析_旧操作结果不覆盖新操作` |
| 旧歌曲迟到回调 | `迟到回调_旧曲transition被忽略` |
| 队列切换与进度回退 | `队列切换_进度回退被抑制` |
| 重复订阅 / 重复事件 | `重复订阅与重复事件_幂等` |
| 取消后迟到事件 | `取消后_引擎释放与作用域取消后迟到事件不写状态` |
| 空队列 / 无效索引 | `空队列与无效索引_无操作且不发射` |
| 计时任务启动/暂停/恢复/取消/释放 | `睡眠定时通道_初始为null且设置后立即有值并每秒递减`、`_取消后置null且不再有任何发射`、`_重设取消旧ticker并以新时长重启`、`_到点写null并停止且不暂停不改mode`、`_切歌与停止不取消倒计时`、`_作用域取消后ticker释放不再发射` |
| 不应合并的错误 / 播放结束 | `高频节流_错误事件仍完整到达归约器`、`高频节流_播放结束与队列切换事件仍完整到达归约器` |
| 低频快照不随秒发射 | `睡眠定时通道_低频快照不随倒计时每秒发射` |

**核心验收**：`高频位置_低频快照发射次数不随采样率线性增长` —— 50ms 节奏 200 样本 vs 200ms 节奏 50 样本，`state` 发射次数差 ≤ 2（均 ≈11，由 1s 节流决定），且 `state` 发射数 × 10 ≤ `position` 发射数。满足路线图完成条件「播放中 `PlaybackState`（低频）发射次数不随位置推进线性增长；位置流单独可用」。

---

## 4. 与 Dart 原实现的差异登记

| # | 差异 | 依据 / 理由 |
|---|---|---|
| 1 | **切歌 / 停止 / 暂停不取消睡眠定时 ticker**（任务措辞 §5.2-8 要求取消，**未采纳**） | Dart `_sleepTimerTicker` 仅在 `setSleepTimer`（`:5280`）、到点（`:5303`）、`dispose`（`:5832`）三处取消；睡眠定时是**墙钟**倒计时，设计意图即跨曲目持续。若按字面在切歌时取消，会导致「30 分钟睡眠定时被一次切歌清零」，破坏 F-KEEP-007 产品契约。已显式测试记录（`睡眠定时通道_切歌与停止不取消倒计时`）。<br>✅ **2026-10-15 产品已确认：保持现状**（睡眠定时不随切歌取消）。风险 R4-04 据此关闭，本行为由「刻意偏离待确认」转为**已确认的既定契约**。 |
| 2 | 引擎 release **无 Store 可见信号** | `EngineListener` 无释放回调，`PlaybackStore` KDoc 亦声明「本类不 release 引擎」。最小风险选择：ticker 绑 `scope`，经作用域取消释放。给 `EngineListener` 加 `onEngineReleased()` 属公开 API 变更，超出本任务边界。 |
| 3 | 暂停 / 恢复对 ticker **无对应语义** | Dart ticker 无 pause/resume，倒计时不随播放暂停而停；native 保持一致。 |
| 4 | 到点后 `state.sleepTimerRemaining` 停在设置值 | 到点迁移属 T-P1-09；本阶段低频快照不随秒刷新。差异是**阶段性的**，T-P1-09 收敛。 |
| 5 | `position` 通道本身未改动 | 审计确认已在 T-P1-02 交付；本次只补 `sleepTimerRemaining` 与 KDoc。 |
| 6 | `clock()` 生产取墙钟（`System.currentTimeMillis`） | 与 Dart `DateTime.now()` 同源，受系统时钟跳变（NTP / 用户改时间）影响；Dart 同款，未额外加固。 |

## 5. 本阶段未完成项

| 项 | 归属 |
|---|---|
| 到点暂停、`SleepTimerMode` 迁移、`stopAfterTimerEnds` 执行、END_OF_TRACK 到点等待态 | **T-P1-09**（`runSleepTimerTicker` 到点分支已留 `TODO T-P1-09` 日志） |
| 引擎释放信号的 Store 可见化 | T-P1-09 或拆卸路径任务 |
| UI 接线（订阅 `sleepTimerRemaining`） | UI 任务（本次未动 UI） |

## 6. 真机验证限制

沙箱**无 Android 设备 / 模拟器**。本报告全部结论来自 JVM/Robolectric（`robolectric.properties` 固定 `sdk=32`）单元测试，**未**验证真机上的倒计时走字节奏、省电策略下的 `delay` 精度、以及切后台后的 ticker 行为。
