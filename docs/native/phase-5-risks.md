# 第五阶段 · 风险登记（phase-5-risks）

> 范围：**T-P1-13**（离线歌单播放，提交 `908d349`）+ **T-P1-08**（音频焦点运行时）+
> **T-P1-10/11**（持久化与数据层基础）
> 前序风险见 `docs/native/phase-4-risks.md`（R4-01 ~ R4-09、R3-05/06/13）

---

## 1. 总览

| ID | 描述 | 严重度 | 状态 | 归属 |
|---|---|---|---|---|
| R5-01 | 缓存上限为常量 512 MiB，未读用户设置 | 🟡 | 开放 | F-CACHE-009 |
| R5-02 | `SimpleCache` 用 legacy 文件索引 | 🟡 | 开放 | 后续 |
| R5-03 | 源记忆未加密 | 🟢 | 开放（登记） | 后续 |
| R5-04 | 缓存命中率未实测 | 🔴 | 开放 | 用户实测 |
| R5-05 | `Previous` 方向不做缓存过滤 | 🟢 | 开放（待确认） | 产品 |
| R5-06 | 缓存降级档位语义（键=请求档，字节可能=降级档） | 🟢 | 开放（登记） | — |
| R5-07 | 真机断网切歌 / 弱网 / Android 7–9 未验证 | 🔴 | 开放 | 用户实测 |
| R5-10 | `abortCrossfade()` 未接入焦点路径 | 🟡 | 开放 | **T-P1-07 必须补** |
| R5-11 | `onExternalRecoveryTrigger()` 无调用方 | 🟢 | 开放（登记） | 后续 |
| R5-12 | 真机焦点行为全未验证 | 🔴 | 开放 | 用户实测 |
| R5-13 | `ProcessLifecycleOwner` 的 700ms `onStop` 延迟 | 🟢 | 接受（官方行为） | — |
| R5-14 | Media3 内置 `GAIN → PLAY_WHEN_READY` 无法区分用户中断期暂停 | 🟡 | 开放（上游行为） | 上游 / 后续 |
| R5-20 | 值去重对「仅 `Song` 字段变化」不敏感 | 🟢 | 开放（跨域评审） | — |
| R5-21 | 恢复位置未按曲目时长钳位 | 🟡 | 开放 | 后续 |
| R5-22 | 恢复时机仅接在 `MediaSessionService.onCreate` | 🟡 | 开放 | UI 接入时评估 |
| R5-23 | SharedPreferences 非加密 | 🟢 | 开放 | 后续 |
| R5-24 | 真机「杀进程重启还原」未验证 | 🔴 | 开放 | 用户实测 |

### 1.1 前序风险状态变化（本阶段）

| ID | 原状态 | 现状态 | 依据 |
|---|---|---|---|
| **R4-01** 恢复链前后台语义被抹平 | 🟡 开放 | 🟡 **部分关闭** | 生产者已接入（`ProcessLifecycleAppForegroundMonitor`）+ `isAppBackgrounded` 状态位；但「按前后台差异化重试」**有意不做**（见 `phase-5-audio-focus.md` §5） |
| **R4-02** `NETWORK_UNAVAILABLE` 不可达 | 🟡 开放 | ✅ **已关闭** | T-P1-13 接线真实网络探测 |
| R4-03 HTTP 状态码反射提取 | 🟡 开放 | 🟡 开放 | 本阶段未触及 |

---

## 2. 重点风险展开

### R5-10 🟡 `abortCrossfade()` 未接入焦点路径（T-P1-07 必须补）

- **事实**：Dart `_handleMedia3FocusChange` 在 `keepPlaying` 的 `LOSS` 分支与 `pauseAndResume` 的非 `GAIN` 分支都**先**调 `abortCrossfade()` 再暂停。native 的交叉淡化（T-P1-07）**尚未落地**，故 `AudioFocusController.handleFocusChange` 暂不调用。
- **影响**：T-P1-07 落地后若忘记补调用，淡化中收到焦点事件会留下**未收敛的 incoming 播放器**——Dart 注释记录该路径会造成「切歌时音量突然变大」（`abort` 把已 promote 的 incoming 音量从斜坡低值一次性拉到用户音量）。
- **处置**：T-P1-07 的完成条件中**必须**包含「在 `handleFocusChange` 补 `abortCrossfade()`」。
- **登记位置**：`AudioFocusController.handleFocusChange` KDoc、`phase-5-audio-focus.md` §4.2。

### R5-14 🟡 Media3 内置 `GAIN` 恢复无法区分「用户中断期间主动暂停」

- **事实**：`PAUSE_AND_RESUME` 模式下 `willPauseWhenDucked=true`，Media3 内置对 `LOSS_TRANSIENT` 执行 `WAIT_FOR_CALLBACK`（把 `playWhenReady` 置 false），对 `GAIN` 执行 `PLAY_WHEN_READY`（无条件 `play()`）。若用户在中断期间主动暂停，内置路径仍会恢复播放。
- **影响**：宿主侧的 `pausedByInterruption` 能保证**宿主不主动恢复**，但**无法阻止 Media3 内置恢复**（需要更深的 fork 改动）。
- **为何不改**：①Dart 同样存在该问题（未处理）；②改 fork 的 `handlePlatformAudioFocusChange` 会影响所有使用该 fork 的分支（含 lite），属跨分支改动。
- **缓解**：`onUserTransportIntent` 在用户暂停时清标志，宿主不会再补一次 `Resume`；最坏是 Media3 恢复后用户再按一次暂停。
- **归属**：上游行为 / 后续（若真机复现明显，再评估 fork 改动）。

### R5-22 🟡 恢复时机仅接在 `MediaSessionService.onCreate`

- **事实**：冷启动恢复的调用点是 `Md3MediaSessionService.onCreate`。若 App 冷启动**不**拉起 Service（例如用户只浏览列表、从未触发播放域），则不会恢复。
- **判断**：**可接受**——`MediaSessionService` 在 `MainActivity` 绑定播放域时即被拉起（`MediaController` 连接），且未播放时恢复队列也无用户可见价值。
- **归属**：UI 接入（P3）时评估是否需要更早的恢复点。

### R5-20 🟢 值去重对「仅 `Song` 字段变化」不敏感

- **事实**：`PersistenceCoordinator.persistCursor` 用 `PersistedPlaybackCursor`（含 `PlaybackQueue` data class）做值去重；而 `PlaybackQueue` 的 `equals` 会经 `Song.equals`（**仅比 id**），故「只改了某曲 `title` 而位置/音量/队列结构都没变」时不会触发写入。
- **影响**：最坏少写一次盘（下次任何其它状态变化都会带上最新队列）。
- **为何不修**：修需要为 `Song` 引入逐字段比较或独立的「队列修订号」参与去重，属跨域改动（`Song.equals` 是 Dart 契约，被队列去重/身份对账大量依赖）。
- **归属**：跨域评审（与 T-P1-13 的 D1 缺陷同源：`Song.equals` 仅比 id）。

---

## 3. 需人类介入的决策

1. **R5-05**：`Previous` 方向是否也要缓存过滤？（当前只做「前进」，产品已确认；若后续要求对称，需新增策略分支）
2. **R5-01**：缓存上限的产品约定值（当前 512 MiB 为临时决策）——F-CACHE-009 设置项落地时确定。
3. **R5-21**：恢复位置是否需要按曲目时长钳位？（Dart 也未做）
4. **R4-06 / R4-08**（前序遗留）：看门狗阈值、自动跳歌范围——仍需真机或产品定夺。
