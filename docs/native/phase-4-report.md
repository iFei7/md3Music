# 第四阶段 · 交付报告（phase-4-report）

> 本报告是第四阶段（**T-P1-04 高频双通道与定时剩余流** + **T-P1-06 恢复执行与错误自动跳歌**）的**合并交付报告**，
> 汇总分项文档（`phase-4-concurrency-audit.md` / `phase-4-recovery.md` / `phase-4-validation.md` / `phase-4-risks.md`）
> 与**阶段收尾反馈的三项处置**。
> 语义基准：Dart `lib/providers/player_provider.dart` 与工作区 `docs/implementation-roadmap.md`。
> **纪律**：所有「已完成」均附证据（提交 / 文件 / 命令 / 数字）；未执行项一律标注「未执行」，不估算、不夸大。
> 最后更新：2026-10-16。

---

## 0. 一页速览

| 维度 | 结论 |
|---|---|
| 交付范围 | T-P1-04（高频双通道与定时剩余流）、T-P1-06（恢复执行与错误自动跳歌） |
| 提交 | **`e1265c1`**「feat(native): implement playback concurrency and recovery」，基线 `a0656b6`，19 文件 / **+3182 / -82** |
| 分支 / 远端 | `native`；**已推送** `origin/native` |
| 单测 | 656（开工基线）→ 673（T-P1-04）→ **690 全绿**（`--rerun-tasks` 实测 0 失败 / 0 错误 / 0 跳过） |
| 门禁 | `projects` / `assembleDebug` / `lintDebug` / `assembleDebugAndroidTest` **全部通过**；`lint-baseline.xml` 未动 |
| 关闭的风险 | **R3-05**、**R3-06**（本阶段）；**R4-02**、**R4-04**（收尾追补，2026-10-15/16） |
| 遗留 | R4-01 / R4-03 / R4-05 / R4-06 / R4-07 开放；R3-13 真机验证**完全未执行** |
| 阶段边界 | 未越界（未做 T-P1-07/08/09/10/11、P2、P3、下载/离线曲库、USB 独占、depth3d） |

---

## 1. 整体进度

第四阶段交付时，native 分支 HEAD 由 `a0656b6` 推进到 **`e1265c1`**。
此后按你的反馈完成了三项收尾处置（§4），并推进了第五阶段 T-P1-13；当前 HEAD 为 `908d349`。

**本阶段在播放链路中的位置**：

```
P1-5b 引擎适配层 + 5 道闸门接线（b606d87）
        │
        ├─ T-P1-04（本阶段）── 高频通道分层：state（低频快照）/ position（~200ms）/ sleepTimerRemaining（1s）
        │
        └─ T-P1-06（本阶段）── 错误分类 → 预算 → 单飞 → 恢复执行 / 自动跳歌
                │
                └─ T-P1-13（第五阶段）── 离线前进过滤（复用本阶段的恢复链分类门与代次机制）
```

---

## 2. 已完成项（附证据）

### 2.1 T-P1-04 · 高频双通道与定时剩余流

**审计确认的真实语义**：Dart `PlayerProvider` 只有全量通知一种粒度，位置流 ~200ms 若走全量通知会导致整页抖动，
故另开两条**独立** `ValueNotifier`：`positionNotifier`（`:537`，~200ms）与 `sleepTimerRemainingNotifier`（`:742-743`，1s）。
两者**只通知自己，不触发 `notifyListeners()`**。

**实现（`PlaybackStore.kt`，三条通道分层）**：

| 通道 | 生产者 | 类型 | 频率 |
|---|---|---|---|
| `state`（低频快照） | 归约器（唯一写路径） | `PlaybackState` | 离散事件 + 1s 节流 |
| `position` | `onPositionSample`（T-P1-02 已交付） | `Duration` | ~200ms |
| `sleepTimerRemaining` | `runSleepTimerTicker`（**本阶段新增**） | `Duration?` | 1s |

- 新增 API：`val sleepTimerRemaining: StateFlow<Duration?>`（`PlaybackStore.kt:241`；`null` = 无进行中的倒计时）。
- **单一权威入口**：ticker **只写高频通道**，从不写 `PlaybackState`；`state.sleepTimerRemaining` 仍由归约器写。
- 生命周期：`reconcileSleepTimerTicker`（`:703-717`）在 `SetSleepTimer(d)` 时「取消旧 Job → 通道立即写满额 → 启新 ticker」；
  `SetSleepTimer(null)` 取消并写 `null`；到点写 `null` + 自停（**不暂停、不迁移 mode**，留 `TODO T-P1-09`）；作用域取消即释放。
- 并发纪律：`@MainThread` 单例、**不用 Mutex**（加锁会掩盖「从后台线程派发」的模型错误）；
  **未使用** `conflate` / `debounce` / `collectLatest`；**无** `Channel`、无无界队列；
  两个 ticker 均为可取消的 `while (isActive) { delay(...) }` 协程；高频路径只做常量算术与 `MutableStateFlow` 赋值（无 I/O）。
- 复用既有闸门，**不重复实现**：`PlaybackRequestGate`（latest-wins 代次）、`PositionRewindGate`（假回退抑制）、
  `PlaybackProgressGate`、`PlaybackErrorEventGate`、`PlaybackStallPolicy`。

**证据**：`HighFrequencyChannelTest.kt`（新增，735 行 / **17 条**）；核心验收
`高频位置_低频快照发射次数不随采样率线性增长` —— 50ms 节奏 200 样本 vs 200ms 节奏 50 样本，
`state` 发射次数差 ≤ 2（均 ≈11，由 1s 节流决定），满足路线图完成条件
「播放中 `PlaybackState`（低频）发射次数不随位置推进线性增长；位置流单独可用」。

**明确未实现（属 T-P1-09）**：到点暂停、`SleepTimerMode` 迁移、`stopAfterTimerEnds` 执行、END_OF_TRACK 到点等待态。

### 2.2 T-P1-06 · 恢复执行与错误自动跳歌

**B1 错误传播链**：引入载体 `PlaybackErrorInfo`（`model/PlaybackError.kt`，340 行）替代哨兵 `-1`，
透传 `message`（仍经 `safePlaybackErrorMessage` 收敛）+ `errorCode` / `errorCodeName` /
`httpStatusCode`（反射遍历 cause 链）+ `origin`（`ENGINE` | `RESOLUTION`）+ `songId`。
选型理由：Kotlin 接口加形参会让**全部既有实现（含测试假件）**同步改签名，且后续再加字段会再次打断；
载体把信息聚成可演进对象且签名稳定。**原始异常 / URL / Token 不进载体**（不泄漏敏感信息）。

**B2 预算**：**复用既有 `PlaybackRecoveryBudget`（1:1 移植 Dart，本阶段零改动、零重写）**——
按单曲计算、`maxAttempts = 3`、退避 `[30s, 60s, 120s]`、**仅 `TRANSIENT_RESOLUTION` 消耗**（分类门之后才 `tryConsume`）、
成功 / 用户播放意图 / 换歌即重置、由单飞保证不重复消耗。

**B3 执行器**：新增 `RecoveryOrchestrator.kt`（394 行），**复用** Budget + Flight，**未重复创建**功能重叠的恢复管理器。
宿主窄接口 `RecoveryHost`（`isRequestCurrent` / `currentSong` / `playlistSize` / `isResolvingUrl` /
`isNetworkAvailable` / `dispatchIntent`）——执行器只「读事实、派意图」，**不直接写状态、不碰引擎**
（状态变化一律经既有 UDF 契约：意图 → Reducer → 效果）。
R3-06 二择一取**选型 ①**：恢复决策后派 `PlaybackIntent.RetryCurrent`，**`PlaybackEffect.RetryPlayback` 已删除**。
新增 20s 超时看门狗（Dart 无，登记为偏离）兜底令牌永久占位。
代次**不引入第三套体系**：播放请求代次复用 `PlaybackRequestGate`；单飞与定时器代次复用 `PlaybackRecoveryFlight`。

**B4 自动跳歌边界（逐条落实）**：**仅解析失败（`RESOLUTION_FAILED`）自动跳**；引擎 / HTTP / 解码错误不跳（对齐 Dart）；
空队列 / 单曲不跳；队尾与循环模式的目标**完全委托归约器 `Next` 的既有队列语义**（索引算术不重写）；
用户手动切歌立即取消待处理恢复，旧恢复的迟到失败按 `songId` 身份忽略；`consecutiveSkips >= playlistSize - 1` 停止；
**听书付费章节不自动跳**。

**B5 测试**：`RecoveryOrchestratorTest.kt`（新增，727 行 / 15 条）+ `ExoPlayerPlaybackEngineAdapterTest.kt`（+2 条错误透传）。
全部断言**最终状态 / 执行次数 / 预算消耗 / 取消行为**，而非「某方法被调用」。
**测试第 2 轮暴露并修复 1 处真实实现缺陷**：`onFailure` 在「在途恢复期间的重复错误」上提前释放令牌，
导致退避链断裂（单曲队列永久卡在第一次重试）——修复为「在途 + `origin == ENGINE` + `RETRY` → 单飞去重返回；
`origin == RESOLUTION` 的完成事件不走该分支」。

### 2.3 关联关闭项

| 编号 | 原问题 | 关闭依据 |
|---|---|---|
| **R3-05** | errorCode 透传缺口 | B1：`EngineListener.onError(PlaybackErrorInfo)` 载体透传真实码，哨兵 `-1` 废弃，中断码 10000000 被正确忽略 |
| **R3-06** | `RetryPlayback` 无生产者 | 选型 ①：恢复链派 `PlaybackIntent.RetryCurrent`，`PlaybackEffect.RetryPlayback` 删除；phase-3 两份文档已回写 |

### 2.4 交付物清单（`e1265c1`，19 文件 / +3182 / -82）

**新增生产文件（2）**：`player/model/PlaybackError.kt`（340）、`player/store/RecoveryOrchestrator.kt`（394）。

**修改生产文件（6）**：`player/store/PlaybackStore.kt`（+284）、`player/engine/ExoPlayerPlaybackEngineAdapter.kt`、
`player/state/PlaybackIntent.kt`、`player/store/PlaybackEffect.kt`（**-12，删除 `RetryPlayback`**）、
`player/store/PlaybackEngine.kt`、`player/store/PlaybackReducer.kt`。

**测试（4）**：新增 `player/store/HighFrequencyChannelTest.kt`（735 / 17 条）、
`player/store/RecoveryOrchestratorTest.kt`（727 / 15 条）；修改 `player/engine/ExoPlayerPlaybackEngineAdapterTest.kt`（+2）、
`player/store/{PlaybackReducerTest,PlaybackStoreTest}.kt`。

**文档（6）**：新增 `docs/native/phase-4-{concurrency-audit,recovery,validation,risks}.md`；
回写 `docs/native/phase-3-{playback-store,risks}.md`。

---

## 3. 验证结果（实测，可复算）

| # | 命令 | 退出码 | 结果 |
|---|---|---|---|
| 1 | `./gradlew projects` | 0 | BUILD SUCCESSFUL；工程层级 `:app` + `:media3fork` |
| 2 | `./gradlew :app:testDebugUnitTest --rerun-tasks` | 0 | **suites=48 / tests=690 / failures=0 / errors=0 / skipped=0** |
| 3 | `./gradlew :app:assembleDebug` | 0 | BUILD SUCCESSFUL |
| 4 | `./gradlew :app:lintDebug` | 0 | BUILD SUCCESSFUL；`Lint found 2 warnings`（均为**既有**告警，落在本阶段未改动文件） |
| 5 | `./gradlew :app:assembleDebugAndroidTest` | 0 | BUILD SUCCESSFUL |

**单测增量**：656 → 673（T-P1-04，+17）→ **690**（T-P1-06，+17）。`suites` 46 → 48。
**无既有测试被删除、弱化或跳过**（`skipped=0`）。

**lint 核验**：可见 2 条告警为 `NewerVersionAvailable`（okhttp，`libs.versions.toml:23`）与
`UseKtx`（`data/source/LoudnessStorePrefs.kt:45`），**均非本阶段引入**；`app/lint-baseline.xml` **未被修改**。

**开发过程中的失败与修复（如实记录）**：T-P1-06 子任务经 3 轮验证循环——① 编译失败（测试内嵌类可见性、`cancel` 未导入）→ 修复；
② 3 个测试失败 → 修复（暴露并修复上述 1 处真实缺陷）；③ 全绿。**无一轮以放宽断言或屏蔽错误收尾。**

---

## 4. 阶段收尾反馈的三项处置（2026-10-15 / 2026-10-16）

| 反馈 | 处置 | 证据 |
|---|---|---|
| **① 睡眠定时不随切歌取消** | ✅ **产品确认保持现状**，**无需改码**；行为由「刻意偏离待确认」转为**已确认的既定契约**（对位 Dart `_sleepTimerTicker` 墙钟语义 + F-KEEP-007「30 分钟定时不被一次切歌清零」）。**R4-04 关闭** | `phase-4-concurrency-audit.md` §4-1、`phase-4-risks.md` R4-04、测试 `睡眠定时通道_切歌与停止不取消倒计时` |
| **② 未触发 GitHub Pre-release** | 实测根因：`e1265c1` **已在** `origin/native`，但 GitHub Actions 对它 **`total_count = 0`**（无任何 run）、release tag 返回 **404** → 属「推送后事件偶发丢失」（同类先例 `b606d87`）。处置：重新推送业务提交 **`908d349`** → **Native CI run #14 `completed / success`**，tag `v1.0.0-grace-native-908d349` **HTTP 200**、`prerelease: true`、资产 `GraceMusic-native-v1.0.0-grace-908d349.apk`（20,968,394 B）已上传 | 工作区 `docs/ci-signing-prebuild-guide.md` §1.1 / §1.2 |
| **③ 断网时在线歌单播放行为** | 属**产品新增行为**（Dart 无对应实现），已作为第五阶段 **T-P1-13** 交付：缓存层 + 网络端口 + 离线前进过滤 + **R-4（网络恢复不自动续播）**。**R4-02 由此关闭**（`isNetworkAvailable()` 返回真实值 → `NETWORK_UNAVAILABLE` 分支可达 → 离线失败**不消耗预算、不排期退避**） | `docs/native/phase-5-{offline-playlist,validation}.md`；提交 `908d349` |

> **②的连带修复**：本次把「网络恢复不自动续播」作为产品决策 4 落地后，本阶段 `RecoveryOrchestrator.onExternalRecoveryTrigger()`
> 的**触发源已变更**——`PlaybackEvent.NetworkChanged` 不再驱动它（仅保留 `AppForegroundChanged`）。
> 该差异已登记于 `phase-4-recovery.md` §6 第 8 行。

---

## 5. 遗留风险

| 编号 | 项 | 严重度 | 状态 | 说明 / 归属 |
|---|---|---|---|---|
| **R3-13** | 真机验证缺失 | 🔴 | **开放** | 本阶段新增能力（睡眠定时通道、恢复链、自动跳歌）**全部未真机验证** |
| **R4-01** | 恢复链前后台语义被抹平 | 🟡 | 开放（已登记） | `AppForegroundChanged` 仍**无生产者**；恢复一律按退避重试，不区分前后台（Dart 仅后台排期）。归属 T-P2 / T-P1-08 |
| **R4-03** | HTTP 状态码反射提取 | 🟡 | 开放（真机未验） | 反射失败即 `null`，安全降级；**前提已变化**——第五阶段已引入 `media3-datasource`，可改为直接引用 `InvalidResponseCodeException` 并去反射（未改，登记为后续收敛项） |
| **R4-05** | 引擎释放无 Store 可见信号 | 🟡 | 开放 | 定时器释放依赖作用域取消；当前无「引擎单独释放而作用域存活」的路径。归属 T-P1-09 / 拆卸路径 |
| **R4-06** | 恢复超时看门狗 20s 为新增阈值 | 🟡 | 开放 | Dart 无对应；慢网（>20s 未收敛）会判超时并排下一轮。需真机调优 |
| **R4-07** | 预算 `nextDelay` 读取时机与 Dart 偏移一档 | 🟡 | 开放（已登记） | native 为「消费前读取」（首档 30s），Dart 为「消费后读取」；已按 native 语义写测试 |
| **R4-08** | 自动跳歌仅「解析失败」触发 | 🟢 | 已登记 | **对齐 Dart**（`errorStream` 不调 `next()`）；若期望「任何失败都自动跳」则不符 |
| **R4-09** | 阶段边界未越界 | 🟢 | 合规 | 变更仅落在 `player/` 域 + `docs/native/`；无 `third_party` / Rust / Flutter / `lite` 改动；未改 `minSdkVersion=24`、`com.gracemusic.app`、namespace；未新增生产依赖 |

**新增登记（第五阶段连带）**：**R5-03** —— `onExternalRecoveryTrigger()` 仍挂在「回到前台」上；
当前无生产者故不可达，但**接入 T-P1-08 前后台信号时必须复核 R-4**（「离线失败 + 网络恢复 + 回到前台」会自动重试）。

---

## 6. 需人类介入的点

| # | 事项 | 状态 / 请求 |
|---|---|---|
| 1 | **R4-04 睡眠定时切歌语义** | ✅ **已拍板**（2026-10-15 产品确认保持现状），无需再介入 |
| 2 | **真机验证基线（R3-13，🔴）** | **仍需你执行**。建议至少一轮：真机弱网 / 断网→恢复 / 在线起播 / 连续解析失败跳歌 / 睡眠定时走字与切后台。**在完成前，本阶段所有「真机可用性」声明一律不成立** |
| 3 | **恢复超时 20s 阈值（R4-06）** | 需真机弱网解析耗时分布后再定是否调整 |
| 4 | **R4-08 自动跳歌范围** | 若产品期望「任何失败都自动跳」（而非仅解析失败），需明确拍板，否则维持 Dart 语义 |
| 5 | **T-P1-08 前置** | 接入 `AppForegroundChanged` 生产者时须一并满足：① 焦点中断（`LOSS`）暂停不得被恢复链误判为可重试失败；② 复核 R-4（网络恢复不得自动续播） |

---

## 7. 真机验证限制（**必须随报告一并阅读**）

沙箱**无 Android 设备 / 模拟器**，`cargo` **未安装**（本阶段 Rust 零改动）。本报告全部结论来自
JVM / Robolectric 单测（`robolectric.properties` 固定 `sdk=32`）与静态审计。

**未验证**：真机弱网恢复、断网→恢复、连续解析失败跳歌、20s 看门狗阈值手感、退避 30/60/120s 实际手感、
睡眠定时走字节奏与省电策略下的 `delay` 精度、切后台后的 ticker 行为、
反射取 HTTP 状态码在真机 R8 混淆后的可用性、Android 7–9（API 24–28）兼容性。

---

## 8. 本阶段未完成项（如实登记）

| 项 | 归属 |
|---|---|
| 睡眠定时到点执行（暂停 / `SleepTimerMode` 迁移 / `stopAfterTimerEnds` / END_OF_TRACK 等待态） | **T-P1-09**（`runSleepTimerTicker` 到点分支已留 `TODO T-P1-09`） |
| 引擎释放信号的 Store 可见化 | T-P1-09 / 拆卸路径 |
| 睡眠定时 UI 接线（订阅 `sleepTimerRemaining`） | UI 任务（本阶段未动 UI） |
| 恢复链「异常结束有限重试」（`_abnormalEndRetries`，F-RCV-002） | 后续恢复任务 |
| 音质降级链（F-RCV-003） | 后续恢复任务 |
| T-P1-07 交叉淡化 / T-P1-08 焦点运行时 / T-P1-10-11 持久化 / P2 数据层 / P3 UI | **均未实现**（本阶段未越界） |

---

## 9. 引用

- 分项文档：`docs/native/phase-4-concurrency-audit.md`、`phase-4-recovery.md`、`phase-4-validation.md`、`phase-4-risks.md`
- 前序：`docs/native/phase-3-{playback-store,risks,gates-audit,engine-validation}.md`、`phase-3b-source-resolver.md`
- 后续：`docs/native/phase-5-{offline-playlist,validation}.md`（T-P1-13）
- 工作区：`docs/implementation-roadmap.md`（§T-P1-04 / §T-P1-06 / §T-P1-13）、`docs/feature-migration-matrix.md`（§4 / F-KEEP-007 / F-RCV）、`docs/ci-signing-prebuild-guide.md`
- 语义基准：Dart `lib/providers/player_provider.dart`（`positionNotifier:537`、`sleepTimerRemainingNotifier:742-743`、`_sleepTimerTicker:5300-5315`、`_retryFailedPlayback:1089-1095`、`errorStream:1705`）
