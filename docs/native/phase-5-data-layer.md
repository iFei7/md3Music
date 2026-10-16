# 第五阶段 · 持久化与数据层基础（phase-5-data-layer）

> 任务：**T-P1-11**（队列持久化序列化）+ **T-P1-10**（播放游标持久化 / 恢复）
> 关联矩阵项：F-QUE-015、F-KEEP-005、F-SET-031、F-PERS-001
> 关联风险：R-14（依赖 `PlaybackState` 序列化）

---

## 1. 落地前现状审计（源码核实）

| 事实 | 位置 | 结论 |
|---|---|---|
| `FlushPersistence` 意图存在 | `state/PlaybackIntent.kt` | 归约产生 `PersistPlaybackCursor` 效果 |
| `PersistPlaybackCursor` **无执行器** | `store/PlaybackStore.kt` 原 `Log.w("...TODO T-P1-10")` | T-P1-10 的核心缺口 |
| `PlaybackQueue` **无序列化** | `player/queue/PlaybackQueue.kt` | T-P1-11 的核心缺口 |
| `Song` 无 toJson/fromJson | `data/model/Song.kt:9-12` KDoc 明示「native 数据层（P2）落序列化约定时再补」 | 同上 |
| `SetRestoreMemoryEnabled` 归约只落盘 | `store/PlaybackReducer.kt` | 无状态位，冷启动无法判定 |
| 无 Room / DataStore 绑定 | `di/DatabaseModule.kt` / `di/DataStoreModule.kt` 均为**空骨架**（仅 KDoc TODO） | 见 §2.1 选型 |
| 既有持久化先例 | `data/source/LoudnessStorePrefs.kt`、`player/offline/ResolvedSourceMemory.kt` | 均走应用私有 SharedPreferences |
| `Song.equals` 仅比 `id` | `data/model/Song.kt:123-127` | **状态发射一致性风险**，见 §5 |

---

## 2. 交付内容

### 2.1 数据所有权与选型（C1 / C2）

**持久化 vs 内存（明确边界）**

| 数据 | 归属 | 位置 |
|---|---|---|
| 歌曲元数据（21 字段） | **持久化** | 队列 JSON（`PersistedSong`） |
| 当前播放队列 + 当前曲 + 索引 + 随机 + 循环 | **持久化** | 队列 JSON（`PersistedQueue`） |
| 上次播放位置 | **持久化** | `player_position` |
| 用户音量 | **持久化** | `player_volume` |
| 用户设置（焦点 / 记忆开关 / 音质） | **持久化** | `PersistPreference`（T-P2 设置层落地前只登记键） |
| **临时音源 URL / Token / Cookie** | **不持久化** | `PersistedSong` 刻意无 `url` 字段 |
| 恢复 Flight / 退避定时器 / 看门狗 | 内存 | `RecoveryOrchestrator` |
| 焦点状态 / 前后台标志 | 内存 | `AudioFocusController` / `PlaybackState` |
| 错误态 / 在途标志 | 内存 | `PlaybackState`（`resolveError` / `isResolvingUrl` 等） |

**存储选型：SharedPreferences（非 Room / DataStore）——源码依据**

1. **Dart 对位就是 SharedPreferences**：`PlayerStateRepository` 全部经 `SharedPreferences.getInstance()`（`player_state_repository.dart:66-140`），键名即 Dart 的 `_key*` 常量。迁到 Room 会失去键级对位，增加「同一份状态两处格式」的风险。
2. **工程既有先例**：`LoudnessStorePrefs`、`SharedPreferencesResolvedSourceMemory` 都走应用私有 SharedPreferences；`DataStoreModule` / `DatabaseModule` 仍是空骨架，引入 DataStore/Room 会同时引入「键归一（T-P2-03）」与「实体/DAO/迁移」两套未落地前提。
3. **数据规模**：游标 + 一份队列 JSON，量级几十 KB，远未到需要事务/索引/查询的规模。

> **登记为待收敛项**：若 P2 数据层统一到 Room，`SharedPreferencesPlaybackCursorStore` 应迁移为 `PlayerStateDao`，键映射保持不变。

**未新建空接口**：本阶段只引入 `PlaybackCursorStore`（端口）、`PlaybackPersistence`（端口）两个接口，各有一个生产实现 + 一个语义明确的 NoOp 降级实现；未创建 UseCase 层或 Repository 包装（无实际消费方）。

### 2.2 T-P1-11：队列序列化

**`player/queue/PlaybackQueueCodec.kt`**（`object`，纯函数）

- `@Serializable internal data class PersistedSong`（21 字段 = `Song` 的 22 个构造参数去掉 `url`）
- `@Serializable internal data class PersistedQueue`（`playlist` / `originalPlaylist` / `currentIndex` / `shuffleEnabled` / `loopMode`）
- `encode(queue): String` —— 恒不抛异常
- `decode(text): PlaybackQueue?` —— **绝不抛异常**（损坏 → `null`）

**关键设计决策**

| 决策 | 理由 |
|---|---|
| **独立 DTO，不给 `Song` 加 `@Serializable`** | ①不污染语义敏感的领域模型（其 `equals` 被显式改写为仅比 id）；②可精确控制持久化边界 |
| **DTO 刻意不含 `url`** | 在线音源是**短期签名链接**（含签名/过期/鉴权参数），属「不允许作为永久数据持久化」的敏感信息。Dart 是「先落盘再在恢复时清空」（`player_provider.dart:1391-1399`）；native **根本不落盘**，效果等价但磁盘零残留 |
| **`originalPlaylist` 一并持久化** | Dart 只存 `playlist`、恢复时把 `_originalPlaylist` 重置为同一列表，导致「随机模式下关闭随机」永久丢失原顺序。native 的 `PlaybackQueue` 是内聚值对象，如实存两份 |
| **`loopMode` 用 `name` 而非 `ordinal`** | `ordinal` 在枚举重排时静默错位；`name` 最坏只是未知值回落 `OFF`（有显式兜底） |
| **`currentIndex` 解码后钳位** | 防越界（对位 Dart `player_state_repository.dart:191`）；空队列 → `-1` |

### 2.3 T-P1-10：游标持久化与恢复

**`player/store/PlaybackCursorStore.kt`**

- `data class PersistedPlaybackCursor(queue, position, volume, dataVersion)`
- `interface PlaybackCursorStore`：`save` / `flush` / `restore` / `clear`（全 `suspend`，禁止主线程 I/O）
- `class SharedPreferencesPlaybackCursorStore(context, io = Dispatchers.IO)`：
  - `Mutex` 单写者串行化；`flush` = 拿锁即等（排空语义）；
  - `apply()` 异步落盘（不阻塞调用线程）；`flush()` 收敛进程被杀窗口；
  - `restore` 逐层 try-catch，**任何损坏 → `null`**（冷启动降级为空白播放器，绝不崩溃）。
- `interface PlaybackPersistence`：`persistCursor(state)` / `flush` / `restore` / `clear`
- `object NoOpPlaybackPersistence`：测试/降级
- `class PersistenceCoordinator(store, @StoreScope scope) : PlaybackPersistence`
  - `persistCursor`：**值去重**（与上次快照相同 → 直接返回）；写入在 `scope.launch` 里，失败**不重试、不伪装成功**（记日志丢弃本轮）
- `shouldSkipRestoredSong(song, fileExists)` / `shouldSkipRestoredQueue(queue, fileExists)`：幽灵歌曲守卫（纯函数，`fileExists` 可注入）

**键映射（对齐 Dart `PlayerStateRepository`）**

| native 键 | Dart 键 | 值 |
|---|---|---|
| `player_playlist` | `player_playlist` | 队列 JSON（**含** index / loop / shuffle） |
| `player_position` | `player_position` | Long（毫秒） |
| `player_volume` | `player_volume` | Float |
| `player_state_data_version` | —— | native 新增：数据格式版本 |

> **与 Dart 的差异（登记）**：Dart 把 `player_current_index` / `player_loop_mode` / `player_shuffle_enabled` **各存一键**；native 内嵌进队列 JSON。理由：native 的 `PlaybackQueue` 是内聚值对象（`PlaybackState` KDoc 明确批评过 Dart「同一结构两处各存一份」导致的状态错位），拆键存储会重新引入「队列 JSON 里的 index」与「独立 index 键」两个真相源。代价是失去逐键对位（已登记），收益是结构上不可能出现索引与队列不同步。

**保存 / 恢复时机**

| 时机 | 触发 | 位置 |
|---|---|---|
| 保存 | `PersistPlaybackCursor` 效果（装载 / 暂停 / seek / 队列结构变化 / 音量 / 循环模式） | `PlaybackStore.execute` |
| 排空 | `FlushPersistence` 意图（退桌面 / 退出前） | `PlaybackStore.dispatch(intent)` |
| 恢复 | 冷启动 | `Md3MediaSessionService.onCreate` → `PlaybackStore.restorePersistedPlayback()` |

**恢复决策链**（对位 Dart `_restoreState`，`player_provider.dart:1350-1438`）

```
1. restoredOnce 守卫（Service 可被反复拉起，恢复必须幂等）
2. !restoreMemoryEnabled → clear() + return false   （Dart 同：清残留）
3. persistence.restore() == null → return false     （无数据 / 损坏 / 版本不匹配）
4. shouldSkipRestoredQueue(queue, fileExists) → clear() + return false  （幽灵歌曲）
5. 音量快照回灌 → dispatch(SetVolume)
6. dispatch(RestorePersistedCursor(queue, position)) → 装载，**不自动播放**
```

**`PlaybackIntent.RestorePersistedCursor`**（新增词汇）
- 归约：整体替换队列、位置作装载起点、清错误态与瞬态标志、`isPlaying = false`；
- 效果：`Prepare(..., playWhenReady = false)`（本地曲）或 `ResolveSongUrl`（在线曲）；
- **不发 `PersistPlaybackCursor`**（避免「恢复 → 落盘 → 恢复」写放大）；
- 不复用 `PlayAt` / `PlayPlaylistFrom`（它们恒 `playWhenReady = true`，会让冷启动直接出声）。

### 2.4 文件清单

**新增生产文件（3）**
- `player/queue/PlaybackQueueCodec.kt`（T-P1-11）
- `player/store/PlaybackCursorStore.kt`（T-P1-10：端口 + 实现 + 协调器 + 守卫）

**修改生产文件（5）**
- `player/state/PlaybackState.kt`（+`restoreMemoryEnabled`）
- `player/state/PlaybackIntent.kt`（+`RestorePersistedCursor`）
- `player/store/PlaybackReducer.kt`（`SetRestoreMemoryEnabled` 写字段；`RestorePersistedCursor` 归约）
- `player/store/PlaybackStore.kt`（`persistCursor` 真实执行、`FlushPersistence` 排空、`restorePersistedPlayback`）
- `player/session/Md3MediaSessionService.kt`（冷启动恢复调用点）
- `di/PlayerModule.kt`（+2 绑定）

**新增测试（3）**
- `player/queue/PlaybackQueueCodecTest.kt`（15 条）
- `player/store/PlaybackCursorStoreTest.kt`（19 条）
- `player/store/PersistenceWiringStoreTest.kt`（11 条）

**追加测试（1）**
- `player/store/PlaybackReducerTest.kt`（+6 条，含 1 条契约演进改写）

---

## 3. 数据一致性（C4）

| 场景 | 处理 | 测试 |
|---|---|---|
| 连续快速写入 | `Mutex` 单写者串行化，天然有序 | `连续快速写入_最后一次生效` |
| 写入失败 | 协调器吞掉并记日志，**不重试不伪装成功**；下一轮状态变化再尝试 | `协调器_写入失败不抛出且不伪装成功` |
| 应用进程意外终止 | `apply()` 异步窗口由 `flush()` 收敛（退桌面 / 退出前） | `flush 返回后写入已可见` |
| 数据缺失或损坏 | `restore()` 逐层 try-catch → `null` → 冷启动降级为空白播放器 | `损坏 JSON 返回 null 不抛异常`、`队列 JSON 损坏时 restore 返回 null 不抛异常` |
| 旧版本数据迁移 | 版本不匹配 → 视为不可用并清空（**本阶段只有版本 1**，未来引入版本 2 时必须补显式迁移分支） | `版本不匹配时 restore 返回 null` |
| 歌曲已不存在 / 队列索引失效 | `decode` 钳位索引；`shouldSkipRestoredQueue` 拦下「当前曲不可用」的整队列 | `索引越界被钳位到末位`、`恢复_幽灵歌曲时清空并返回 false` |
| 播放位置超出有效时长 | **本阶段不处理**（见 §6 遗留风险 R5-21） | —— |

---

## 4. 与 Dart 的差异登记

| # | 差异 | 理由 |
|---|---|---|
| 1 | **不落盘 `url`**（Dart 落盘后恢复时清空） | 安全要求：签名 URL 不属可持久化数据 |
| 2 | **`originalPlaylist` 一并持久化**（Dart 恢复时重置） | 保真「关闭随机还原原顺序」 |
| 3 | **index / loop / shuffle 内嵌队列 JSON**（Dart 各存一键） | 避免两个真相源 |
| 4 | **新增 `dataVersion` 键**（Dart 无） | 显式版本门，避免旧结构被误解读 |
| 5 | **恢复不自动播放**（与 Dart 一致） | —— |
| 6 | 恢复时**不重新装载封面通知**（Dart 恢复完成后主动推一次通知元数据） | 通知刷新归 T-P1-03+（`RefreshSystemNotification` 仍是 TODO） |

---

## 5. `Song.equals` 与状态发射一致性（C4 硬性要求）

**现状**：`Song.equals` 仅比较 `id`（对位 `song.dart:215-221`），`hashCode` 取 `id.hashCode`。

**已发生的真实事故（T-P1-13 阶段修复）**：`PlaybackStore.apply` 是 `_state.value = transition.state`，`MutableStateFlow` 按相等性去重——`Song` 的**纯字段级更新**（如回写 `url`）会让新 state 与旧 state 结构性相等而被**静默吞掉**，导致离线跳缓存曲时 `url` 回写不生效、击穿 R-1/R-2。修法是把「回写源」与「起播」**合并为一次状态迁移**（`PlaybackIntent.PlayAt(index, source)`），使迁移必然改变其它字段而无法被去重。

**本阶段的三层区分（按要求逐条回应）**

| 问题 | 结论 |
|---|---|
| ① 对象内容发生变化 | 会（`copy` 产生新对象，但 `equals` 仍为 true） |
| ② 对象引用发生变化 | 会（`copy` 是新实例） |
| ③ 持久化内容发生变化 | **会**——`PlaybackQueueCodec` 是**逐字段**序列化，不经 `equals`；因此字段级变化在磁盘上可见 |
| ④ `StateFlow` 是否实际发射新状态 | **不会**（被 `MutableStateFlow` 相等去重）——这是**已知语义**，非缺陷 |

**处置（按要求：不以改 `equals` 或加 `distinctUntilChanged` 掩盖）**
- **不**改 `equals`（它是 Dart 契约，且被队列去重/身份对账大量依赖）；
- **不**加 `distinctUntilChanged`（掩盖问题）；
- **持久化层不受影响**：`PersistenceCoordinator` 的**值去重**比较的是 `PersistedPlaybackCursor`（含 `PlaybackQueue` data class 的逐字段 `equals`）——等等，`PlaybackQueue` 是 data class，其 `equals` 会比较 `playlist` 列表，而 `Song.equals` 仅比 id，因此**纯字段级变化在协调器的去重里同样不可见**。

> **登记为遗留风险 R5-20**：`PersistenceCoordinator.persistCursor` 的值去重对「仅 `Song` 字段变化」不敏感，可能少写一次盘。**影响可控**：位置/音量/队列结构的任何变化都会改变 `PersistedPlaybackCursor` 的其它字段从而触发写入；最坏后果是「只改了某曲的 `title` 而位置音量都没变」时不落盘。**不修**（修需要为 `Song` 引入逐字段比较，属跨域改动），如实登记。

---

## 6. 未完成项与遗留风险

### 6.1 未完成（如实登记）

| 项 | 归属 |
|---|---|
| `PersistPreference` / `PersistFavoriteToggle` 仍为 TODO（设置层 / 收藏仓库未落地） | T-P2 设置层 / 数据层 |
| 恢复时不重新装载封面通知 | T-P1-03+ |
| `Previous` 方向的持久化一致性专项测试 | 后续 |
| Room / DataStore 迁移 | P2 数据层 |

### 6.2 遗留风险

| ID | 描述 | 严重度 | 归属 |
|---|---|---|---|
| R5-20 | 值去重对「仅 `Song` 字段变化」不敏感（见 §5） | 🟢 | 跨域评审 |
| R5-21 | 恢复位置**未**按曲目时长钳位（Dart 也未做；`validateSeekTarget` 只在 seek 路径生效） | 🟡 | 后续 |
| R5-22 | 恢复时机仅接在 `Md3MediaSessionService.onCreate`；若 App 冷启动**不**拉起 Service（纯 UI 浏览），则不触发恢复 | 🟡 | UI 接入时评估 |
| R5-23 | `SharedPreferences` 非加密（`MODE_PRIVATE` 是应用隔离而非静态加密）；队列元数据不含凭据，风险低 | 🟢 | 后续（如引入 `EncryptedSharedPreferences`） |
| R5-24 | 真机「杀进程重启还原队列/进度/音量」**未执行**（沙箱无设备） | 🔴 | 用户实测 |

---

## 7. 真机验证限制

沙箱无 Android 设备/模拟器。以下**未执行**，不得宣称通过：
- 杀进程重启后队列 / 进度 / 音量还原；
- 开关关闭时不还原；
- 大队列（数千首）的序列化耗时与落盘延迟；
- 退桌面 / 退出时 `flush()` 是否真的在进程被杀前完成。
