# 第四阶段 · 恢复执行与错误自动跳歌（phase-4-recovery）

> 本报告记录第四阶段 **T-P1-06 恢复执行与错误自动跳歌**（B1 错误透传 / B2 RecoveryBudget / B3 Flight 执行器 / B4 自动跳歌 / B5 测试）的审计结论、最终实现与偏离登记。
> 语义基准：Dart `lib/providers/player_provider.dart`（链 B `_retryFailedPlayback`）与既有纯逻辑闸门 `PlaybackRecoveryBudget` / `PlaybackRecoveryFlight`。
> 关联：`docs/native/phase-3-gates-audit.md`（G4/G5）、`docs/native/phase-3-risks.md` R3-05 / R3-06（本阶段关闭）。

---

## 1. B1 错误传播链（补齐前 → 补齐后）

### 1.1 补齐前的缺口

```
media3 PlaybackException
  └─ ExoPlayerPlaybackEngineAdapter.onPlayerError(error)
       只取 error.message 经 safePlaybackErrorMessage 收敛 → listeners.onError(message)
       ★ 丢失 errorCode / errorCodeName / httpStatusCode / cause
  └─ EngineListener.onError(message: String)
  └─ PlaybackStore.StoreEngineListener.onError(message)
       shouldHandlePlaybackErrorEvent(errorCode = ERROR_CODE_NOT_PROVIDED /* 哨兵 -1 */, ...)
       ★ 哨兵 -1 ≠ Dart 中断码 10000000，无法区分切歌中断
  └─ PlaybackEvent.EngineError(message) → PlaybackReducer.engineError(state, message)
       ★ 不带错误分类，无恢复调度入口
```

### 1.2 补齐后的链路

```
media3 PlaybackException
   │  adapter.onPlayerError(error)                                    ExoPlayerPlaybackEngineAdapter.kt:244-
   ▼
PlaybackErrorInfo(message = safePlaybackErrorMessage(...),            model/PlaybackError.kt
                  errorCode, errorCodeName,
                  httpStatusCode = extractHttpStatusCode(cause 链),
                  origin = ENGINE|RESOLUTION, songId)
   │  listeners.forEach { it.onError(info) }
   ▼
EngineListener.onError(info: PlaybackErrorInfo)                       PlaybackEngine.kt
   │  PlaybackStore.StoreEngineListener.onError(info)                 PlaybackStore.kt:585
   ▼
PlaybackErrorEventGate.shouldHandlePlaybackErrorEvent(errorCode ?: -1, isCurrentRequest, loadCompleted)
   │  放行
   ▼
PlaybackStore.handlePlaybackFailure(info)                             PlaybackStore.kt:617
   ├─ dispatch(PlaybackEvent.EngineError(info)) → Reducer（纯函数，只迁移状态/文案）
   └─ recovery.onFailure(info, activeRequestGen)  → 恢复决策入口（拿到原始码 + 分类）
```

解析失败路径：`PlaybackStore.resolveSongUrl` 失败 → `PlaybackErrorInfo.resolutionFailure(message, songId)`（`PlaybackStore.kt:534`）→ 同一决策入口。

### 1.3 API 选型说明（为何用载体而非形参扩展）

任务要求「不要机械地新增同名方法；如果现有 API 已有错误对象、错误码或封装，应先评估其表达能力，在保持兼容性的前提下补齐缺失信息」。

选型 = **引入 `PlaybackErrorInfo` 载体**，理由：
1. Kotlin 接口方法一旦加形参，**全部既有实现（含测试假件）签名必须同步**，且后续再加字段会再次打断；载体把「文案 + 原始码 + 码名 + HTTP 码 + 来源 + 曲目身份」聚成可演进对象，签名稳定。
2. `message` 仍是 `safePlaybackErrorMessage` 收敛值——**原始异常 / URL / Token 不进载体**，不泄漏敏感信息。
3. `origin` 区分「引擎错误」与「解析失败」，使恢复链能区分「在途恢复自身失败」与「外部新错误」（见 §3 并发去重）。

### 1.4 错误分类与动作映射（`classifyPlaybackError` + `recoveryActionFor`，均为**纯函数**）

| 类别 | 判据 | 恢复动作 |
|---|---|---|
| `RESOLUTION_FAILED` | origin = RESOLUTION | **SKIP**（自动跳歌） |
| `USER_CANCELED` | 码 `10000000`（切歌中断，良性） | **IGNORE** |
| `ENGINE_RELEASED` | media3 `ERROR_CODE_DISCONNECTED` = -100 | **IGNORE** |
| `AUTHENTICATION_REQUIRED` | media3 `ERROR_CODE_AUTHENTICATION_EXPIRED` = -102 | **STOP** |
| `PAID_CONTENT` | media3 `ERROR_CODE_PREMIUM_ACCOUNT_REQUIRED` = -103 / `Song.isLongAudio` | **STOP** |
| `HTTP_NETWORK` | 2000–2008、HTTP 401/403/408/425/429/5xx | **RETRY** |
| `TIMEOUT` | media3 `ERROR_CODE_TIMEOUT` = 1003 | **RETRY** |
| `DECODE` / `SOURCE_INVALID` / `INTERNAL` | 3001–3004 / 4001–4006 / 1000–1004 等 | **复用** `shouldAutomaticallyRetryPlatformPlaybackError`：3003 / 4004 / 4005 与 404 / 410 / 400 / 422 → STOP，其余 RETRY |

**纪律落实**：①不把所有错误当可重试网络错误（未知码归 `INTERNAL`，按确定性兼容问题判定）；②用户主动切歌（10000000）与引擎释放（-100）→ IGNORE，不触发恢复；③解析失败抛出的异常在 `resolveSongUrl` 内不吞、经 `EngineError` 上抛，恢复失败不伪造成功；④日志只含任务编号与固定文案。

> **HTTP 状态码提取**：`:app` 只依赖 media3-common/decoder，不引 media3-datasource，故 `extractHttpStatusCode` 用反射遍历 cause 链读取 `InvalidResponseCodeException.responseCode`；取不到即 `null`。**属偏离，真机未验**（见 phase-4-risks.md）。

---

## 2. B2 RecoveryBudget 规则

**复用既有 `PlaybackRecoveryBudget`（1:1 移植 Dart，本阶段零改动、零重写）**。

| 维度 | 规则 | 依据 |
|---|---|---|
| 计算单位 | **按单曲**（`tryConsume(songId)`；不同 songId 先 `reset`） | Dart `:1131` + `playback_recovery_budget.dart:141-146` |
| 次数 / 退避 | `maxAttempts = 3`，`backoff = [30s, 60s, 120s]` | Dart `:77-113` 默认值 |
| 何时消耗 | **仅 `TRANSIENT_RESOLUTION` 消耗**——分类门（`classifyPlaybackRecoveryFailure`）之后才 `tryConsume`；认证 / 付费 / 断网 / 用户取消**不消耗** | Dart `:1126-1135` |
| 何时重置 | 成功（`onPlaybackHealthy`）→ `budget.reset(songId)`；用户播放意图 → `reset`；换歌 → `tryConsume` 内自动 reset | Dart `:1159` |
| 并发重复消耗 | 由 `flight.tryStart()` 单飞 + 在途重复错误去重保证**不重复消耗** | Dart `:1104-1105` |
| 防无限重试 / 风暴 | 上限 3 次；退避最小 30s（**无立即重试路径**）；`scheduleBackoff` 已有排期即返回（去重） | Dart `:1189-1210` |

**差异登记**：`budget.nextDelay` 的读取时机——native 为「消费前读取」（首次等待 30s），Dart 为「消费后读取」，存在**一档偏移**；已按 native 语义写测试并登记（`恢复_短暂网络故障后按退避重试成功` 断言首档 30s）。

---

## 3. B3 Flight / 恢复执行器

新增 `native/app/src/main/kotlin/com/gracemusic/player/store/RecoveryOrchestrator.kt`（394 行），**复用** `PlaybackRecoveryBudget` + `PlaybackRecoveryFlight`，**未重复创建**功能重叠的恢复管理器。

宿主窄接口 `RecoveryHost`（`isRequestCurrent` / `currentSong` / `playlistSize` / `isResolvingUrl` / `isNetworkAvailable` / `dispatchIntent`）：执行器只「读事实、派意图」，**不直接写状态、不碰引擎**——状态变化一律经既有 Store/Reducer 契约（UDF：意图 → Reducer → 效果）。

### 3.1 执行流程（逐条对应任务要求）

| # | 要求 | 实现 |
|---|---|---|
| ① | 接收带错误分类与播放代次的失败事件 | `onFailure(info, gen)` |
| ② | 验证仍属当前播放请求 | `host.isRequestCurrent(gen)` + `info.songId != currentSong.id` → 丢弃旧曲迟到失败 |
| ③ | 按类别 + 预算选动作 | `recoveryActionFor(info)` + `budget.tryConsume`（分类门之后） |
| ④ | 经受控执行器执行 | `dispatchSelf(PlaybackIntent.RetryCurrent)`——不直调引擎 |
| ⑤ | 处理成功 / 失败 / 取消 / 超时 / 迟到 | 令牌 + 代次 + 曲目身份三重校验；超时看门狗见 3.3 |
| ⑥ | 状态变化经 Store/Reducer 契约反映 | 仅派意图，归约器写状态 |
| ⑦ | 预算耗尽 / 不可恢复 → 停止 / 错误态 / 跳歌 | `STOP` → 保留错误态；`SKIP` → `maybeAutoSkip`；预算耗尽 → `stopTimers` |
| ⑧ | 每次失败最多一次有效恢复决策 | 单飞 + 退避去重 + 在途解析守卫 + `origin` 区分 |

### 3.2 R3-06 二择一 → **选型 ①**

恢复链决策后**派发 `PlaybackIntent.RetryCurrent` 意图**，复用既有已验证路径（`RetryCurrent → ResolveSongUrl / Prepare → UpdateSong → 重备`）。据此 **`PlaybackEffect.RetryPlayback` 已删除**（原无生产者、语义与 `RetryCurrent` 重叠），同步更新了 Store 执行器分支、`PlaybackEffect` KDoc、`docs/native/phase-3-risks.md` R3-06 与 `docs/native/phase-3-playback-store.md`。

### 3.3 超时看门狗（Dart 无，新增）

`RECOVERY_TIMEOUT_MS = 20_000`：在途恢复超过 20s 仍无收敛事件 → 释放令牌 + 按退避排下一轮。Dart 依赖 `_resolveAndPlayCurrentSong` 的 Future 完成，无显式超时；native 的 `RetryCurrent` 是「派意图 + 观察事件」的异步形态，需要兜底避免令牌永久占位。**登记为偏离**。

### 3.4 代次与结构化并发

- **代次（不引入第三套体系）**：播放请求代次复用 `RecoveryHost.isRequestCurrent`（Store 的 `PlaybackRequestGate` / `activeRequestGen`）；恢复单飞与定时器代次复用 `PlaybackRecoveryFlight`（`inFlightToken` 单飞、`sequence` 作废迟到定时器）。
- **定时器**：退避 / 看门狗全部 `delay` + 注入 `@StoreScope`；**无** `Thread.sleep`、**无** `Timer`、**无**无界 `Channel`。
- **可取消**：`onUserPlaybackIntent()`（切歌 / 起播 / 重试 / seek / 暂停 / 停止 / 清空队列）与 `cancel()`（Service 销毁 / 引擎释放路径）立即作废旧 Flight；编排器**自派发**的 `RetryCurrent` / `Next` 经 `selfDispatchDepth` 隔离，不会取消自己。
- **不覆盖用户新意图**：用户播放族意图 → `onUserPlaybackIntent()` → 释放令牌 + `flight.invalidate()` + 停定时器。

---

## 4. B4 自动跳歌边界（逐条）

| 边界 | 行为 | 测试 |
|---|---|---|
| 当前曲失败后是否自动跳歌 | **仅解析失败（`RESOLUTION_FAILED`）自动跳**；引擎 / HTTP / 解码错误**不跳**（对齐 Dart `errorStream` 不调 `next()`） | `恢复_解析失败自动跳下一首` |
| 空队列 | 不崩、不派意图 | `恢复_单曲与空队列不跳歌` |
| 只有一首歌 | `playlistSize <= 1` 不跳 | 同上 |
| 最后一首歌失败 | 目标完全**委托归约器 `Next`** 的既有队列语义：OFF 队尾 → 提示 + 停机；ALL → 绕回队首；ONE 多曲 → 前进 | `恢复_循环模式决定跳歌目标` |
| 单曲循环 / 列表循环 / 随机 | 同上（索引算术不重写，复用 `PlaybackQueue`） | 同上 |
| 用户手动切换当前曲 | 立即取消待处理恢复；旧恢复的迟到失败按 `songId` 身份被忽略 | `恢复_用户切歌取消待处理恢复`、`恢复_旧曲迟到解析失败被忽略` |
| 连续多首失败限制跳转循环 | `consecutiveSkips >= playlistSize - 1` 停止（等价 Dart `next()` 循环「全部试过」） | `maybeAutoSkip` + `恢复_单曲与空队列不跳歌` |
| 用户暂停 / 主动停止时是否允许后台恢复推进队列 | 暂停 / 停止属播放族意图 → 取消恢复；**退避定时器不区分前后台**（偏离，见下） | `恢复_作用域取消后定时器不再触发` |
| 新用户播放意图取消旧恢复任务 | 是（`onUserPlaybackIntent`） | `恢复_用户切歌取消待处理恢复` |
| 听书付费章节 | **不**自动跳（整专辑大概率连续付费，Dart `:3343-3344 / :3475-3476 / :4722-4723`） | `maybeAutoSkip` 首行守卫 |

---

## 5. B5 测试（新增 17 条）

`RecoveryOrchestratorTest.kt`（15 条）+ `ExoPlayerPlaybackEngineAdapterTest.kt`（新增 2 条错误透传用例）：

| 场景 | 测试名 |
|---|---|
| 短暂网络故障后恢复成功 | `恢复_短暂网络故障后按退避重试成功` |
| 预算耗尽 | `恢复_预算耗尽后第四次不再重试` |
| 不可恢复错误 | `恢复_确定性音源与解码错误不重试` |
| 解析失败触发的恢复路径 | `恢复_解析失败自动跳下一首` |
| 旧代次错误被忽略 | `恢复_旧曲迟到解析失败被忽略` |
| 重复错误只触发一次恢复 | `恢复_重复错误只排一次恢复` |
| 用户主动切歌后旧 Flight 被取消 | `恢复_用户切歌取消待处理恢复` |
| 恢复期间再次出现新错误 | `恢复_恢复期间新错误不并发重复恢复` |
| 队列为空 / 只有一首歌 | `恢复_单曲与空队列不跳歌` |
| 单曲循环 / 列表循环 / 随机 | `恢复_循环模式决定跳歌目标` |
| 引擎释放 / Service 销毁时任务取消 | `恢复_作用域取消后定时器不再触发` |
| 恢复过程异常不伪造成功 | `恢复_重试抛异常不伪造成功` |
| 换歌后预算归零 | `恢复_换歌后预算归零` |
| 错误透传（含中断码忽略） | `错误透传_错误码到达决策入口且中断码被忽略` |
| 分类与动作映射 | `错误分类与恢复动作映射` |

全部断言**最终状态 / 执行次数 / 预算消耗 / 取消行为**，而非「某方法被调用」。

> **测试第 2 轮暴露并修复了 1 处真实实现缺陷**：`onFailure` 在「在途恢复期间的重复错误」上提前释放令牌，导致在途恢复自身的解析失败无法被识别为「重试失败」，**退避链断裂**（单曲队列永久卡在第一次重试）。修复为：在途 + `origin == ENGINE` + `RETRY` → 单飞去重返回；`origin == RESOLUTION` 的完成事件不走该分支。

---

## 6. 与 Dart 原实现的差异登记

| # | 差异 | 理由 |
|---|---|---|
| 1 | 透传形态用 `PlaybackErrorInfo` 载体（非 `onError(message, errorCode)` 形参扩展） | 见 §1.3 |
| 2 | **退避定时器不区分前后台** | Dart 仅 `_isAppBackgrounded` 排期；native 无前后台信号源（`AppForegroundChanged` 无生产者），一律退避重试——避免前台弱网永不恢复 |
| 3 | **失败即排期重试** | Dart 仅由网络恢复 / 类型变化 / 后台定时器触发；native 失败当下即按退避排期（首次 30s），把「外部触发」放宽为「定时触发」，天然防风暴 |
| 4 | 无登录态判定 | Dart 用 `!apiClient.isLoggedIn`；native 无会话层（T-P2-07），改用 media3 `ERROR_CODE_AUTHENTICATION_EXPIRED` |
| 5 | 新增恢复超时看门狗（20s） | 见 §3.3 |
| 6 | `budget.nextDelay` 消费前读取 | 见 §2 差异登记 |
| 7 | 测试用 `RobolectricTestRunner` | `android.util.Log` 在纯 JUnit 下抛 `Stub!`；与既有 Store 测试同一偏离 |

---

## 7. 本阶段未完成项

| 项 | 归属 |
|---|---|
| `isNetworkAvailable()` 恒 `true` → `NETWORK_UNAVAILABLE` 分支**当前不可达** | T-P2 数据/系统层（连接监测） |
| `AppForegroundChanged` 无生产者 → 前后台不分 | T-P2 / T-P1-08 |
| 完整音频焦点运行时 | **T-P1-08** |
| 睡眠定时到点执行 | **T-P1-09** |
| 交叉淡化 | **T-P1-07** |
| 真机弱网 / 断网 / 失效链接 / 连续失败验证 | 用户设备 |

## 8. 真机验证限制

沙箱**无 Android 设备 / 模拟器**。全部恢复链结论来自 JVM/Robolectric 单测（Fake PlaybackEngine + 虚拟时间）。**未验证**：真机弱网恢复、断网→恢复、连续解析失败跳歌、20s 看门狗阈值、退避 30/60/120s 实际手感、反射取 HTTP 状态码在真机 R8 混淆后的可用性。**不得**宣称在线恢复链路真机可用。
