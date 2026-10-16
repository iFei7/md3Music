package com.gracemusic.player.queue

import com.gracemusic.data.model.Song
import com.gracemusic.player.model.AppLoopMode
import kotlin.time.Duration.Companion.milliseconds
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * 持久化用的曲目 DTO（T-P1-11）。
 *
 * ## 为什么是独立 DTO 而不是给 [Song] 加 `@Serializable`
 * 1. **不污染领域模型**：[Song] 的 `equals` / `hashCode` 被显式改写为「仅比 `id`」
 *    （对位 `song.dart:215-221`）。给它加序列化注解会把「序列化关注点」混进
 *    一个语义高度敏感的值对象里，后续任何字段调整都可能悄悄改变持久化格式。
 * 2. **可以精确控制持久化边界**：DTO **刻意不含 `url`**（见下）。
 *
 * ## 不持久化 `url`（相对 Dart 的收紧，安全要求）
 * Dart `PlayerStateRepository` 存 `song.toJson()`（含 `url`），并在恢复时
 * 把在线曲目的 `url` 清空（`player_provider.dart:1391-1399`）——即「先落盘再丢弃」。
 * native **根本不落盘** `url`：在线音源是**短期签名链接**（含签名/过期时间/鉴权参数），
 * 属「不允许作为永久数据持久化」的敏感信息（见 `docs/native/phase-5-data-layer.md` §C1）。
 * 效果等价（恢复后都需重新解析），但磁盘上不会残留任何历史签名 URL。
 *
 * [localPath] 仍持久化：本地曲目的文件路径不是凭据，且是恢复的唯一音源线索。
 *
 * 字段与 [Song] 的 22 个构造参数一一对应（`url` 除外，故为 21 个）。
 */
@Serializable
internal data class PersistedSong(
    val id: String,
    val title: String,
    val artist: String,
    val album: String,
    val durationMs: Long,
    val localPath: String? = null,
    val artworkUri: String? = null,
    val isOnline: Boolean = false,
    val albumId: String? = null,
    val artistId: String? = null,
    val quality: String? = null,
    val albumAudioId: String? = null,
    val fileId: Int? = null,
    val isCloud: Boolean = false,
    val climaxStart: Double? = null,
    val climaxEnd: Double? = null,
    val bpm: Int? = null,
    val isLocallyFavorited: Boolean = false,
    val isLongAudio: Boolean = false,
    val loudnessLufs: Double? = null,
    val loudnessPeakDb: Double? = null,
)

/**
 * 持久化用的队列 DTO（T-P1-11）。
 *
 * ## 为什么连 `originalPlaylist` 一起存（比 Dart 更完整）
 * Dart 只存 `playlist`，恢复时把 `_originalPlaylist` 重置为同一列表
 * （`player_provider.dart:1379-1380`）——于是「随机模式下关闭随机」本应还原的
 * **随机前顺序**在冷启动后永久丢失（用户会看到列表顺序被随机序固化）。
 * native 的 [PlaybackQueue] 把 `playlist` 与 `originalPlaylist` 内聚为一个值
 * （见 `PlaybackState` KDoc 的设计说明），因此这里如实存两份，round-trip 保真。
 *
 * ## `loopMode` 用 `name` 而非 `ordinal`
 * `ordinal` 在枚举成员重排时会静默错位（把 `ALL` 读成 `ONE`），
 * 而 `name` 最坏只是「未知值回落 `OFF`」。解码侧对未知值有显式兜底。
 */
@Serializable
internal data class PersistedQueue(
    val playlist: List<PersistedSong> = emptyList(),
    val originalPlaylist: List<PersistedSong> = emptyList(),
    val currentIndex: Int = -1,
    val shuffleEnabled: Boolean = false,
    val loopMode: String = "OFF",
)

/**
 * [PlaybackQueue] ⇄ JSON 编解码（T-P1-11）。
 *
 * ## 契约
 * - [encode] 恒不抛异常（DTO 是纯数据，`Json` 序列化不会失败）；
 * - [decode] **绝不抛异常**：JSON 损坏 / 字段类型不符 / 未知枚举值 → 返回 `null`
 *   或按兜底值降级。理由：持久化数据来自上一次进程（可能被截断、可能是旧版本格式），
 *   让冷启动因一份坏数据崩溃是不可接受的（Dart 侧同样逐层 try-catch，
 *   `player_state_repository.dart:141-196`）。
 * - `currentIndex` 解码后**钳位**到 `[-1, size-1]`：Dart 同款防越界
 *   （`player_state_repository.dart:191`）。
 *
 * ## 不负责的事
 * 本对象是**纯函数**，不碰磁盘、不碰 SharedPreferences、不读时钟。
 * 落盘时机与写队列由 [com.gracemusic.player.store.PlaybackCursorStore] 负责。
 */
object PlaybackQueueCodec {

    private val json = Json {
        // 向前兼容：旧版本多写的字段不导致解码失败。
        ignoreUnknownKeys = true
        // 显式写出默认值：让持久化内容自描述（排查时不必对照代码猜缺省）。
        encodeDefaults = true
    }

    /** 编码为 JSON 字符串。 */
    fun encode(queue: PlaybackQueue): String =
        json.encodeToString(
            PersistedQueue(
                playlist = queue.playlist.map(::toPersisted),
                originalPlaylist = queue.originalPlaylist.map(::toPersisted),
                currentIndex = queue.currentIndex,
                shuffleEnabled = queue.shuffleEnabled,
                loopMode = queue.loopMode.name,
            ),
        )

    /**
     * 解码；任何失败一律返回 `null`（不抛异常，见对象 KDoc）。
     *
     * 解码成功但队列为空 → 返回**空队列**（而非 `null`）：空队列是合法状态
     * （用户清空过），与「数据损坏」必须可区分。
     */
    fun decode(text: String): PlaybackQueue? {
        val persisted = try {
            json.decodeFromString<PersistedQueue>(text)
        } catch (_: Throwable) {
            return null
        }
        val playlist = persisted.playlist.map(::toSong)
        val original = persisted.originalPlaylist.map(::toSong)
        // 钳位：空队列 → -1；否则落进 [0, size-1]。
        val clampedIndex = when {
            playlist.isEmpty() -> -1
            else -> persisted.currentIndex.coerceIn(0, playlist.lastIndex)
        }
        return PlaybackQueue(
            playlist = playlist,
            // 缺省（旧数据 / 未启用随机）→ 与 playlist 对齐，语义等价于「未随机过」。
            originalPlaylist = original.ifEmpty { playlist },
            currentIndex = clampedIndex,
            shuffleEnabled = persisted.shuffleEnabled,
            loopMode = loopModeOf(persisted.loopMode),
        )
    }

    /** 未知循环模式名 → [AppLoopMode.OFF]（兜底，不抛异常）。 */
    private fun loopModeOf(name: String): AppLoopMode =
        AppLoopMode.entries.firstOrNull { it.name == name } ?: AppLoopMode.OFF

    internal fun toPersisted(song: Song): PersistedSong = PersistedSong(
        id = song.id,
        title = song.title,
        artist = song.artist,
        album = song.album,
        durationMs = song.duration.inWholeMilliseconds,
        localPath = song.localPath,
        artworkUri = song.artworkUri,
        isOnline = song.isOnline,
        albumId = song.albumId,
        artistId = song.artistId,
        quality = song.quality,
        albumAudioId = song.albumAudioId,
        fileId = song.fileId,
        isCloud = song.isCloud,
        climaxStart = song.climaxStart,
        climaxEnd = song.climaxEnd,
        bpm = song.bpm,
        isLocallyFavorited = song.isLocallyFavorited,
        isLongAudio = song.isLongAudio,
        loudnessLufs = song.loudnessLufs,
        loudnessPeakDb = song.loudnessPeakDb,
    )

    internal fun toSong(persisted: PersistedSong): Song = Song(
        id = persisted.id,
        title = persisted.title,
        artist = persisted.artist,
        album = persisted.album,
        duration = persisted.durationMs.milliseconds,
        // 刻意留空：在线音源 URL 是短期签名链接，恢复后必须重新解析。
        url = null,
        localPath = persisted.localPath,
        artworkUri = persisted.artworkUri,
        isOnline = persisted.isOnline,
        albumId = persisted.albumId,
        artistId = persisted.artistId,
        quality = persisted.quality,
        albumAudioId = persisted.albumAudioId,
        fileId = persisted.fileId,
        isCloud = persisted.isCloud,
        climaxStart = persisted.climaxStart,
        climaxEnd = persisted.climaxEnd,
        bpm = persisted.bpm,
        isLocallyFavorited = persisted.isLocallyFavorited,
        isLongAudio = persisted.isLongAudio,
        loudnessLufs = persisted.loudnessLufs,
        loudnessPeakDb = persisted.loudnessPeakDb,
    )
}
