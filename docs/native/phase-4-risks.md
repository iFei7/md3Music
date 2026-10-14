# 第四阶段 · 风险登记（phase-4-risks）

> 承接 `docs/native/phase-3-risks.md` R3-01~R3-13 与 `decisions-and-risks.md` R-01~R-15，仅登记第四阶段（T-P1-04 / T-P1-06）范围内**新发现、未关闭或状态变化**的风险。
> 严重度：🔴 高（可致进程崩溃/功能静默失效）/ 🟡 中（行为偏差/需后续接线）/ 🟢 低（已缓解或有既定计划）。

---

## 状态变化（承接项）

| 编号 | 原状态 | 现状态 | 说明 |
|---|---|---|---|
| **R3-05** errorCode 透传缺口 | 🟡 开放 | ✅ **已关闭** | T-P1-06 B1：`EngineListener.onError(PlaybackErrorInfo)` 载体透传 `errorCode` / `errorCodeName` / `httpStatusCode` / `origin` / `songId`；哨兵 `-1` 已废弃，`PlaybackErrorEventGate` 收到真实码（中断码 10000000 被正确忽略） |
| **R3-06** `RetryPlayback` 无生产者 | 🟡 开放 | ✅ **已关闭** | 二择一取**选型 ①**：恢复链决策后派发 `PlaybackIntent.RetryCurrent`；`PlaybackEffect.RetryPlayback` **已删除**；两份 phase-3 文档已回写 |
| **R3-04** 在线音源阻塞 | 🟡 代码层解除 | 🟡 仍开放（真机待验） | 恢复链已接线，但「在线恢复」的真机行为仍未知 |
| **R3-13** 真机验证缺失 | 🔴 | 🔴 **仍开放** | 本阶段新增能力（睡眠定时通道、恢复链、自动跳歌）**全部未真机验证** |
| **F-KEEP-004** 前后台切换 | 🟡 进行中 | 🟡 仍开放 | `AppForegroundChanged` 仍**无生产者**（ProcessLifecycle 观测未接），恢复策略无法按前后台区分 |

---

## R4-01 🟡 恢复链的前后台语义被抹平（偏离登记）

- **事实**：Dart `_scheduleNextFailedRetry` 仅在 `_isAppBackgrounded` 时排期重试（`player_provider.dart:1194-1196`）；native 无前后台信号源（`AppForegroundChanged` 事件在归约层是 no-op、且无生产者），故 `RecoveryOrchestrator` **一律按退避重试**，不区分前后台。
- **影响**：前台播放失败时也会按 30/60/120s 自动重试，与 Dart「前台等用户手动处理」略有差异。**正向面**：避免前台弱网永不恢复。
- **缓解**：已登记为明确决策（phase-4-recovery.md §6-2）；前后台信号源落地（T-P2 或 T-P1-08）后可按 Dart 语义收紧。
- **验证需求**：真机前台/后台失败场景对比。

## R4-02 🟡 `NETWORK_UNAVAILABLE` 分类分支当前不可达

- **事实**：`RecoveryHost.isNetworkAvailable()` 固定返回 `true`（native 尚无连接可用性监测，connectivity 属 T-P2 数据/系统层），故 `classifyPlaybackRecoveryFailure` 的 `NETWORK_UNAVAILABLE` 分支**永远不命中**。
- **影响**：断网时不做「等待网络恢复」的差异化处理，仍按 30/60/120s 重试（预算 3 次），存在无谓重试。
- **缓解**：预算上限 + 退避已兜底，不会形成风暴。
- **归属**：T-P2 数据/系统层（连接监测接入后接线）。

## R4-03 🟡 HTTP 状态码提取依赖反射（真机未验）

- **事实**：`:app` 只依赖 media3-common/decoder，**未**引 media3-datasource（避免新增依赖），故 `extractHttpStatusCode` 用 `java.lang.reflect` 遍历 cause 链读取 `InvalidResponseCodeException.responseCode`。
- **影响**：若真机 R8 混淆后该类名/字段被改写，提取返回 `null` → HTTP 错误降级为按 media3 `errorCode`（2000–2008）分类，**仍可重试**，不会误判为不可恢复。
- **缓解**：反射失败即 `null`，行为安全降级；已用「公开类」在单测环境验证。
- **验证需求**：真机 release 构建（含 R8）下断链/403/404 的分类表现。

## R4-04 🟡 睡眠定时 ticker 不随切歌/停止取消（刻意偏离）

- **事实**：任务措辞要求「切歌/停止/引擎释放时取消」，实现**按 Dart 权威语义**保留倒计时（墙钟语义），仅在 `SetSleepTimer(null)` / 到点 / 作用域取消时停。
- **影响**：若维护者期望「切歌清零定时」，行为不符；但按字面实现会破坏 F-KEEP-007（30 分钟定时被一次切歌清零）。
- **缓解**：已显式测试记录（`睡眠定时通道_切歌与停止不取消倒计时`）+ phase-4-concurrency-audit.md §4-1 登记。**需人类确认**。
- **验证需求**：产品侧确认预期行为。

## R4-05 🟡 引擎释放无 Store 可见信号

- **事实**：`EngineListener` 无「引擎已释放」回调；`PlaybackStore` 声明不 release 引擎（进程存续）。睡眠定时 ticker 与恢复链的释放依赖**作用域取消**（Service 销毁 / 进程拆卸）。
- **影响**：若存在「引擎单独释放而作用域存活」的路径，定时器不会随之停止。
- **缓解**：当前无该路径（引擎与作用域同为进程级单例）。
- **归属**：T-P1-09 或拆卸路径任务。

## R4-06 🟡 恢复超时看门狗 20s 为新增阈值（Dart 无对应）

- **事实**：`RECOVERY_TIMEOUT_MS = 20_000` 为 native 新增（Dart 依赖 resolve Future 完成）。
- **影响**：慢网络（>20s 未收敛）会被判定超时并排下一轮退避，可能与实际解析时长不匹配。
- **缓解**：超时只释放令牌 + 按退避重排（不消耗额外预算逻辑之外的东西），不会无限循环。
- **验证需求**：真机弱网下解析耗时分布，必要时调整阈值。

## R4-07 🟡 预算 `nextDelay` 读取时机与 Dart 存在一档偏移

- **事实**：native 在**消费前**读 `budget.nextDelay`（首次等待 30s）；Dart 在**消费后**读。
- **影响**：退避档位序列整体前移一档（native：30/60/120；Dart 语义对应后移）。
- **缓解**：已按 native 语义写测试（`恢复_短暂网络故障后按退避重试成功` 断言首档 30s）并登记。

## R4-08 🟢 自动跳歌仅在「解析失败」触发

- **事实**：`SKIP` 动作仅映射自 `PlaybackErrorCategory.RESOLUTION_FAILED`；引擎/HTTP/解码错误走 `RETRY` 或 `STOP`，不跳歌。这是**对齐 Dart**（`errorStream` 处理器不调 `next()`）。
- **影响**：若维护者期望「任何失败都自动跳」，行为不符；但按 Dart 语义正确。
- **缓解**：已登记（phase-4-recovery.md §4 首行）。

## R4-09 🟢 阶段边界未越界（合规确认）

- **事实**：本阶段**未**实现 T-P1-07 交叉淡化、T-P1-08 音频焦点运行时、T-P1-09 睡眠定时执行、T-P1-10/11 持久化、P2 数据层、P3 Compose UI、下载/离线曲库、USB 独占、depth3d。
- **核验**：`git status` 变更仅落在 `player/` 域 + `docs/native/`；无 `third_party` / Rust / Flutter / `lite` 分支改动；未改 `minSdkVersion=24`、包名 `com.gracemusic.app`、namespace `com.gracemusic`；未新增生产依赖；`lint-baseline.xml` 未动。

---

## 风险总览

| 编号 | 项 | 严重度 | 状态 | 归属 |
|---|---|---|---|---|
| R3-05 | errorCode 透传缺口 | 🟡 | ✅ 已关闭 | — |
| R3-06 | `RetryPlayback` 无生产者 | 🟡 | ✅ 已关闭 | — |
| R3-13 | 真机验证缺失 | 🔴 | 开放 | 用户设备 |
| R4-01 | 恢复链前后台语义被抹平 | 🟡 | 开放（已登记） | T-P2 / T-P1-08 |
| R4-02 | `NETWORK_UNAVAILABLE` 不可达 | 🟡 | 开放 | T-P2 数据/系统层 |
| R4-03 | HTTP 状态码反射提取 | 🟡 | 开放（真机未验） | 用户实测 |
| R4-04 | 睡眠定时不随切歌取消 | 🟡 | 开放（需人类确认） | 产品确认 |
| R4-05 | 引擎释放无 Store 信号 | 🟡 | 开放 | T-P1-09 / 拆卸路径 |
| R4-06 | 恢复超时看门狗阈值 | 🟡 | 开放 | 真机调优 |
| R4-07 | 预算退避读取时机偏移 | 🟡 | 开放（已登记） | — |
| R4-08 | 自动跳歌仅解析失败触发 | 🟢 | 已登记 | — |
| R4-09 | 阶段边界未越界 | 🟢 | 合规 | — |

## 进入 T-P1-08（AudioFocusPolicy）前必须满足的条件

1. **R4-04 人类确认**：睡眠定时「切歌是否清零」的产品预期需拍板（影响 F-KEEP-007 契约）。
2. **R3-13 真机基线**：至少完成一轮真机弱网 / 断网恢复 / 在线起播实测，确认恢复链与解析链路真实可用，否则 T-P1-08 的焦点中断将与未验证的恢复链耦合，问题难以定位。
3. **R4-02 / R4-01 的前后台与网络信号源**：T-P1-08 需处理「焦点中断 → 是否标记为可自动恢复」，而该判定依赖前后台与网络状态；建议在 T-P1-08 内一并接入 `AppForegroundChanged` 生产者为最小前置。
4. **焦点与恢复的互斥**：T-P1-08 落地时须明确「焦点中断（`LOSS`）触发的暂停」不得被恢复链误判为可重试失败（当前 `USER_CANCELED` / `ENGINE_RELEASED` 已 IGNORE，但焦点暂停需新增判据）。
