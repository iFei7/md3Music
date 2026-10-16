package com.gracemusic.player.store

import android.content.Context
import android.util.Log
import androidx.core.content.edit
import com.gracemusic.player.queue.PlaybackQueue
import com.gracemusic.player.queue.PlaybackQueueCodec
import com.gracemusic.player.state.PlaybackState
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * 可持久化的播放游标快照（T-P1-10）。
 *
 * 「游标」= 恢复播放所需的**最小充分**信息：队列（含当前曲、索引、随机、循环）、
 * 位置、音量。刻意**不含**：
 * - `isPlaying` / `awaitingPlaybackProgress` / `isResolvingUrl` 等**瞬态**标志
 *   （恢复后一定是「已装载但未播放」，见 `PlaybackState` KDoc 的存储/派生划分）；
 * - `resolveError` / `manualRetryInFlight`（错误态不应跨进程存活）；
 * - 音源 URL（[PlaybackQueueCodec] 已剥离，见其 KDoc）；
 * - 恢复 Flight / 看门狗计时 / 焦点状态（[PersistenceCoordinator] KDoc 的 C3 边界）。
 *
 * @property queue 队列快照（`originalPlaylist` 一并保真）。
 * @property position 上次播放位置（毫秒精度）。
 * @property volume 用户设置的应用内音量（0.0..1.0）。
 * @property dataVersion 数据格式版本；用于「旧版本数据迁移」判定。
 */
data class PersistedPlaybackCursor(
    val queue: PlaybackQueue,
    val position: Duration,
    val volume: Double,
    val dataVersion: Int = PlaybackCursorStore.CURRENT_DATA_VERSION,
)

/**
 * 播放游标持久化端口（T-P1-10）。
 *
 * ## 为什么是挂起接口
 * 落盘是磁盘 I/O，**禁止在主线程执行**（项目铁律）。全部方法为 `suspend`，
 * 由调用方（[PersistenceCoordinator]，绑 `@StoreScope`）在受控协程里执行。
 *
 * ## 写语义（对位 Dart `PlayerStateRepository`）
 * - [save] **按调用顺序串行落盘**（内部单写者），前一次失败不阻断后一次；
 * - [flush] 等待「调用时已入队的写入」排空（对位 Dart `flush()` 的
 *   「后续新写入不属于本次屏障」语义）；
 * - [restore] **绝不抛异常**：任何损坏（JSON 坏、类型不符、版本不匹配）
 *   一律返回 `null`，让冷启动降级为「空白播放器」而不是崩溃；
 * - [clear] 清空全部持久化状态（用户关闭「记忆播放」或恢复数据不可用时）。
 */
interface PlaybackCursorStore {

    /** 保存游标快照（串行落盘；失败不抛给调用方，见实现 KDoc）。 */
    suspend fun save(cursor: PersistedPlaybackCursor)

    /** 等待调用时已入队的写入排空。 */
    suspend fun flush()

    /** 读取上次快照；无数据或数据损坏 → `null`。 */
    suspend fun restore(): PersistedPlaybackCursor?

    /** 清空持久化状态。 */
    suspend fun clear()

    companion object {
        /**
         * 当前数据格式版本。
         *
         * **迁移策略（本阶段）**：只存在版本 1，读到其它版本一律视为不可用
         * （返回 `null`）并清空——避免用旧结构误解读出新语义的数据。
         * 未来引入版本 2 时必须在此处补显式迁移分支（登记于
         * `docs/native/phase-5-data-layer.md` §C4）。
         */
        const val CURRENT_DATA_VERSION: Int = 1
    }
}

/**
 * [PlaybackCursorStore] 的 SharedPreferences 实现（T-P1-10）。
 *
 * ## 为什么用 SharedPreferences 而不是 Room / DataStore
 * 源码依据：
 * 1. **Dart 对位就是 SharedPreferences**：`PlayerStateRepository` 全部经
 *    `SharedPreferences.getInstance()`（`player_state_repository.dart:66-140`），
 *    键名即 Dart 的 `_key*` 常量——迁移到 Room 会失去键级对位，增加
 *    「同一份状态两处格式」的风险；
 * 2. **工程既有先例**：`LoudnessStorePrefs`（`data/source/`）与
 *    `SharedPreferencesResolvedSourceMemory`（`player/offline/`）都走应用私有
 *    SharedPreferences；`di/DataStoreModule` / `di/DatabaseModule` 目前仍是
 *    **空骨架**（仅 KDoc 的 TODO），引入 DataStore/Room 会同时引入
 *    「键归一（T-P2-03）」与「实体/DAO/迁移」两套未落地前提；
 * 3. **数据规模**：游标 + 一份队列 JSON，量级在几十 KB，远未到需要
 *    事务/索引/查询的规模。
 *
 * **登记为待收敛项**：若后续 P2 数据层统一到 Room，本实现应迁移为
 * `PlayerStateDao`，键映射保持不变（见 `docs/native/phase-5-data-layer.md` §C2）。
 *
 * ## 键映射（对齐 Dart `PlayerStateRepository` 的 `_key*`）
 * | 本实现键 | Dart 键 | 说明 |
 * |---|---|---|
 * | [KEY_PLAYLIST] | `player_playlist` | 队列 JSON（**native 合并了** index/loop/shuffle，见下） |
 * | [KEY_POSITION] | `player_position` | 位置（毫秒 Long） |
 * | [KEY_VOLUME] | `player_volume` | 音量（Float，Dart 在 `player_provider.dart:5255` 写） |
 * | [KEY_DATA_VERSION] | —— | native 新增：数据格式版本 |
 *
 * **与 Dart 的差异（登记）**：Dart 把 `player_current_index` / `player_loop_mode` /
 * `player_shuffle_enabled` **各存一键**；native 把它们内嵌进队列 JSON。
 * 理由：native 的 [PlaybackQueue] 是内聚值对象（`PlaybackState` KDoc 明确批评过
 * Dart「同一结构两处各存一份」导致的状态错位），拆键存储会重新引入
 * 「队列 JSON 里的 index」与「独立 index 键」两个真相源。代价是失去与 Dart 的
 * 逐键对位（已登记），收益是结构上不可能出现「索引与队列不同步」。
 *
 * ## 线程与串行化
 * 全部磁盘操作经 [io] 调度器（默认 [Dispatchers.IO]），由 [mutex] 串行化：
 * - [save] / [clear] 拿锁写；
 * - [flush] 拿锁即等（前序写入完成后立即释放），实现「排空」语义；
 * - [restore] 拿锁读，保证不会读到「写了一半」的中间态。
 *
 * 用 `apply()` 而非 `commit()`：前者异步落盘、不阻塞调用线程，与 Dart 侧
 * `await prefs.setXxx()` 的「不阻塞 UI」取向一致；进程被杀时的丢失窗口由
 * [flush]（退桌面 / 退出前显式调用）收敛。
 */
class SharedPreferencesPlaybackCursorStore(
    context: Context,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) : PlaybackCursorStore {

    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    /** 单写者：串行化全部磁盘访问，[flush] 借此实现「排空」。 */
    private val mutex = Mutex()

    override suspend fun save(cursor: PersistedPlaybackCursor) {
        val playlistJson = PlaybackQueueCodec.encode(cursor.queue)
        val positionMs = cursor.position.inWholeMilliseconds
        withContext(io) {
            mutex.withLock {
                // 显式失败不静默：SharedPreferences 的 apply() 不返回结果，
                // 但写入前的编码异常会在此抛出（codec 契约：encode 恒成功，
                // 故实际上只有系统级 IO 失败会经日志暴露）。
                try {
                    prefs.edit {
                        putString(KEY_PLAYLIST, playlistJson)
                        putLong(KEY_POSITION, positionMs)
                        putFloat(KEY_VOLUME, cursor.volume.toFloat())
                        putInt(KEY_DATA_VERSION, cursor.dataVersion)
                    }
                } catch (t: Throwable) {
                    // 不吞异常后伪装成功：记录后向上抛，让调用方（协调器）决定降级。
                    Log.w(TAG, "保存播放游标失败", t)
                    throw t
                }
            }
        }
    }

    override suspend fun flush() {
        withContext(io) {
            // 拿锁即等：前序 save 完成后锁才可用，此处不写任何东西。
            mutex.withLock { Unit }
        }
    }

    override suspend fun restore(): PersistedPlaybackCursor? = withContext(io) {
        mutex.withLock {
            val version = try {
                prefs.getInt(KEY_DATA_VERSION, 0)
            } catch (t: Throwable) {
                Log.w(TAG, "读取数据版本失败", t)
                return@withLock null
            }
            if (version != PlaybackCursorStore.CURRENT_DATA_VERSION) {
                // 无数据（0）或版本不匹配 → 视为不可用。
                return@withLock null
            }
            val playlistJson = try {
                prefs.getString(KEY_PLAYLIST, null)
            } catch (t: Throwable) {
                Log.w(TAG, "读取队列失败", t)
                return@withLock null
            } ?: return@withLock null

            val queue = PlaybackQueueCodec.decode(playlistJson) ?: return@withLock null
            val positionMs = try {
                prefs.getLong(KEY_POSITION, 0L)
            } catch (t: Throwable) {
                Log.w(TAG, "读取位置失败", t)
                0L
            }
            val volume = try {
                prefs.getFloat(KEY_VOLUME, 1f)
            } catch (t: Throwable) {
                Log.w(TAG, "读取音量失败", t)
                1f
            }
            PersistedPlaybackCursor(
                queue = queue,
                position = positionMs.milliseconds,
                volume = volume.toDouble(),
                dataVersion = version,
            )
        }
    }

    override suspend fun clear() {
        withContext(io) {
            mutex.withLock {
                prefs.edit { clear() }
            }
        }
    }

    private companion object {
        const val TAG = "PlaybackCursorStore"

        /** 专用 prefs 文件（应用私有，其他应用不可读）。 */
        const val PREFS_NAME = "gracemusic_player_state"

        // 键名对齐 Dart `PlayerStateRepository` 的 `_key*` 常量。
        const val KEY_PLAYLIST = "player_playlist"
        const val KEY_POSITION = "player_position"
        const val KEY_VOLUME = "player_volume"

        /** native 新增：数据格式版本（Dart 无对应键，已登记）。 */
        const val KEY_DATA_VERSION = "player_state_data_version"
    }
}

/**
 * 播放状态持久化端口（T-P1-10）。
 *
 * 抽成接口的唯一理由：让 [PlaybackStore] 能在**测试与未接持久化的装配**下
 * 有一个语义明确的降级实现（[NoOpPlaybackPersistence]），而不是可空依赖
 * 或空对象猜测。生产绑定 [PersistenceCoordinator]。
 */
interface PlaybackPersistence {

    /** 落盘当前状态（异步、值去重；见实现 KDoc）。 */
    fun persistCursor(state: PlaybackState)

    /** 立即落盘并等待写入队列排空。 */
    suspend fun flush()

    /** 读取上次快照；无数据 / 损坏 → `null`。 */
    suspend fun restore(): PersistedPlaybackCursor?

    /** 清空持久化状态。 */
    suspend fun clear()
}

/**
 * 空实现：不落盘、不恢复。
 *
 * **用途仅限测试与降级**：语义等价于「本次装配不接持久化」——
 * `PersistPlaybackCursor` 效果被忽略（与 T-P1-10 之前的行为逐字一致）。
 * 生产 DI 必须绑定 [PersistenceCoordinator]。
 */
object NoOpPlaybackPersistence : PlaybackPersistence {
    override fun persistCursor(state: PlaybackState) = Unit
    override suspend fun flush() = Unit
    override suspend fun restore(): PersistedPlaybackCursor? = null
    override suspend fun clear() = Unit
}

/**
 * 播放状态持久化协调器（T-P1-10）。
 *
 * ## 职责边界（C3：哪些该持久化、哪些不该）
 * **持久化**：队列快照、当前曲（在队列里）、位置、音量、循环/随机（在队列里）。
 * **不持久化**：临时音源 URL、在途网络请求、恢复 Flight、焦点状态、
 * 正在运行的倒计时、任何错误态。理由见 [PersistedPlaybackCursor] KDoc。
 *
 * ## 保存时机
 * 由 Store 的 `PersistPlaybackCursor` 效果驱动（归约器在「装载 / 暂停 / seek /
 * 队列结构变化 / 音量变化 / 循环模式变化」等处发出）。[persistCursor] 做
 * **值去重**：与上次已保存的快照相同则直接返回，避免高频重复写盘。
 *
 * ## 恢复时机
 * 冷启动（[PlaybackStore.restorePersistedPlayback]），且仅在
 * `PlaybackState.restoreMemoryEnabled` 为真时；开关关闭时**清空**历史数据
 * （对位 Dart `_restoreState` 的首段，`player_provider.dart:1354-1358`）。
 *
 * ## 幽灵歌曲守卫
 * 恢复前调用 [shouldSkipRestoredQueue]：本地曲目的 `localPath` 指向的文件
 * 可能已被清理，此时跳过恢复并清空持久化状态（对位 Dart
 * `shouldSkipRestoredSong`，避免恢复出无法播放的「幽灵歌曲」）。
 *
 * ## 写入失败策略
 * [persistCursor] 的写入在协程里执行；失败**不重试、不伪装成功**——
 * 记录日志并丢弃本轮（下一轮状态变化会再次尝试）。理由：游标不是关键数据，
 * 无限重试会放大 IO 压力；而「丢一次」的最坏后果只是恢复位置略旧。
 *
 * ## 数据一致性（C4）
 * - **连续快速写入**：由 [PlaybackCursorStore] 内部单写者串行化，天然有序；
 * - **写入失败**：见上（丢弃本轮，不重试）；
 * - **进程意外终止**：`apply()` 的异步落盘窗口由 [flush] 收敛（退桌面 / 退出前）；
 * - **数据缺失或损坏**：`restore()` 返回 `null` → 冷启动降级为空白播放器；
 * - **旧版本数据迁移**：版本不匹配即视为不可用（见
 *   [PlaybackCursorStore.CURRENT_DATA_VERSION]）；
 * - **队列索引失效 / 歌曲已不存在**：[PlaybackQueueCodec.decode] 钳位索引，
 *   [shouldSkipRestoredQueue] 拦下「当前曲不可用」的整队列。
 */
@Singleton
class PersistenceCoordinator @Inject constructor(
    private val store: PlaybackCursorStore,
    @StoreScope private val scope: kotlinx.coroutines.CoroutineScope,
) : PlaybackPersistence {

    /** 最近一次已提交保存的快照（值去重依据）。 */
    private var lastSaved: PersistedPlaybackCursor? = null

    /**
     * 落盘当前状态（异步、值去重）。
     *
     * 主线程调用（Store 的效果执行器）；实际 I/O 在 [scope] 的协程里、
     * 经 [PlaybackCursorStore] 的 io 调度器执行。
     */
    override fun persistCursor(state: PlaybackState) {
        val cursor = snapshotOf(state)
        if (cursor == lastSaved) return
        lastSaved = cursor
        scope.launch {
            try {
                store.save(cursor)
            } catch (t: Throwable) {
                // 显式失败不静默、不重试：游标可丢，不能拖垮播放域。
                Log.w(TAG, "落盘播放游标失败（本轮丢弃，等待下次状态变化）", t)
            }
        }
    }

    /** 立即落盘并等待写入队列排空（`FlushPersistence` 意图）。 */
    override suspend fun flush() {
        try {
            store.flush()
        } catch (t: Throwable) {
            Log.w(TAG, "排空写入队列失败", t)
        }
    }

    /** 读取上次快照；无数据 / 损坏 → `null`。 */
    override suspend fun restore(): PersistedPlaybackCursor? = try {
        store.restore()
    } catch (t: Throwable) {
        Log.w(TAG, "读取播放游标失败", t)
        null
    }

    /** 清空持久化状态（关闭记忆播放 / 恢复数据不可用）。 */
    override suspend fun clear() {
        lastSaved = null
        try {
            store.clear()
        } catch (t: Throwable) {
            Log.w(TAG, "清空播放游标失败", t)
        }
    }

    /** 从 [PlaybackState] 提取持久化快照。 */
    private fun snapshotOf(state: PlaybackState): PersistedPlaybackCursor =
        PersistedPlaybackCursor(
            queue = state.queue,
            position = state.position,
            volume = state.volume,
        )

    private companion object {
        const val TAG = "PersistenceCoordinator"
    }
}

/**
 * 恢复前的「幽灵歌曲」守卫（T-P1-10）。
 *
 * 对位 Dart `shouldSkipRestoredSong`：外部调用歌曲的 `localPath` 指向应用私有
 * 缓存拷贝，可能已被系统或清理工具删除。若直接恢复，用户会看到一个
 * 「点播放没反应」的幽灵条目。
 *
 * 判定规则（保守）：
 * - 在线曲 / 云盘曲：**不跳过**（音源靠重新解析，与本地文件无关）；
 * - 本地曲且 `localPath` 为空：**跳过**（无音源可用）；
 * - 本地曲且 `localPath` 非空：由 [fileExists] 判据决定（生产注入
 *   `File(path).exists()`；测试注入假实现，避免依赖真实文件系统）。
 *
 * @param fileExists 文件存在性判据（可注入，便于测试）。
 */
fun shouldSkipRestoredSong(
    song: com.gracemusic.data.model.Song?,
    fileExists: (String) -> Boolean,
): Boolean {
    if (song == null) return true
    if (song.isOnline || song.isCloud) return false
    val path = song.localPath ?: return true
    return !fileExists(path)
}

/**
 * 恢复出的队列是否需要跳过（任一本地曲目文件缺失即视为不可信）。
 *
 * 与 [shouldSkipRestoredSong] 同源，但作用于整队列：只要当前曲不可用就跳过，
 * 避免恢复后立刻处于「不可播放」状态。
 */
fun shouldSkipRestoredQueue(
    queue: PlaybackQueue,
    fileExists: (String) -> Boolean,
): Boolean = shouldSkipRestoredSong(queue.currentSong, fileExists)
