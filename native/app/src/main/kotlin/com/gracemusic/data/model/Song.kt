package com.gracemusic.data.model

import kotlin.time.Duration

/**
 * 应用核心歌曲实体（不可变值对象）。
 *
 * 1:1 移植自 lib/data/models/song.dart:27-222（含全部 KDoc 语义注释）。
 * 字段数与 Dart 逐一对应（22 个构造字段）；Dart 的 fromJson / toJson /
 * copyWith 暂不移植——native 数据层（P2）落序列化约定时再补，
 * Kotlin data class 的 copy() 已覆盖 Dart copyWith 的字段更新场景
 * （含 clearUrl：直接 copy(url = null) 即可，无需哨兵参数）。
 *
 * **相等性语义（重要，song.dart:215-221）**：Dart 侧 `operator ==` 仅比较
 * [id]、`hashCode` 取 `id.hashCode`——同一 id 视为同一首歌（URL 刷新、
 * 标题改写等不改变身份）。此处用显式 equals / hashCode 覆盖保留该语义：
 * data class 生成的逐字段相等被有意替换。消费方如需判断「是否同一曲目」，
 * 直接用 `==` / HashSet 去重即可；如需逐字段比对（如票务 canCommit），
 * 仍按字段显式比较。
 *
 * 时长用 [kotlin.time.Duration]（毫秒精度，纯 JVM 值类型，minSdk 24 无需
 * java.time 脱糖）；Dart 侧 `Duration(milliseconds: ...)` 的构造语义一致。
 */
data class Song(
    /** 歌曲唯一标识（相等性与哈希的唯一依据，见类 KDoc）。 */
    val id: String,
    /** 标题（原始值，可能带 `.mp3` 等扩展名；UI 展示用 [displayName] 剥离）。 */
    val title: String,
    /** 歌手名（可能为占位值，判断「是否未知」一律用 [isUnknownArtist]）。 */
    val artist: String,
    /** 专辑名。 */
    val album: String,
    /** 时长（毫秒精度）。 */
    val duration: Duration,
    /** 播放链接（在线歌曲解析后写入；本地歌曲为 null）。 */
    val url: String? = null,
    /** 本地文件路径（本地歌曲；在线歌曲为 null）。 */
    val localPath: String? = null,
    /** 封面 URI（可空）。 */
    val artworkUri: String? = null,
    /** 是否为在线歌曲（酷狗 API 曲目）；本地扫描曲目为 false。 */
    val isOnline: Boolean = false,
    /** 专辑 ID（预取票务按 id + albumId + albumAudioId 三元组比对曲目身份）。 */
    val albumId: String? = null,
    /** 歌手 ID（可空）。 */
    val artistId: String? = null,
    /** 音质标记（接口返回的曲目音质描述，非用户设置档位）。 */
    val quality: String? = null,
    /** 专辑音频 ID（同曲目不同专辑版本的区分维度，见预取/交叉淡化票务）。 */
    val albumAudioId: String? = null,
    /** 文件 ID（可空）。 */
    val fileId: Int? = null,
    /**
     * 是否为酷狗云盘歌曲（用户上传到云盘）。
     * 播放/投屏时 URL 解析优先走 /user/cloud/url，而非通用 /song/url。
     */
    val isCloud: Boolean = false,
    /** 高潮部分开始时间（秒），由酷狗 /song/climax 接口返回。 */
    val climaxStart: Double? = null,
    /** 高潮部分结束时间（秒），由酷狗 /song/climax 接口返回。 */
    val climaxEnd: Double? = null,
    /**
     * 歌曲 BPM（节拍/分钟），可空。
     *
     * 用于歌词辉光等按快慢歌区分效果的触发判定：
     * 酷狗公开接口暂不返回该字段，当前主要由本地音频标签（如 MP3 TBPM）
     * 或未来接口填充；缺失时上层回落 KRC 歌词字长统计推断快慢。
     */
    val bpm: Int? = null,
    /**
     * 本地收藏标志位（区别于云端"我喜欢"）。
     * true 表示用户在本机收藏过；旧 JSON 缺省时默认为 false，向后兼容。
     */
    val isLocallyFavorited: Boolean = false,
    /**
     * 是否为酷狗听书（长音频）章节。
     * 仅听书专辑详情页构造章节时置 true，用于播放失败时给出更明确的提示
     * （付费边界已按列表接口 fail_process 过滤隐藏；无免费部分的付费章节
     * 点开仍会失败，此时提示该章节为听书VIP单独付费内容）。
     */
    val isLongAudio: Boolean = false,
    /** 音量均衡（响度归一）用：歌曲集总响度（LUFS），可空。 */
    val loudnessLufs: Double? = null,
    /** 音量均衡（响度归一）用：歌曲真峰值（dBTP/dBFS），可空。 */
    val loudnessPeakDb: Double? = null,
) {
    /**
     * 用于 UI 显示的时长——`mm:ss` 两位分秒。
     *
     * 1:1 移植自 song.dart:93-97。注意 Dart 语义：分钟按 60 取回绕
     * （`duration.inMinutes.remainder(60)`），即 1 小时整展示为 "00:00"、
     * 61 分钟展示为 "01:00"——小时位丢失是 Dart 既有行为，此处保持一致。
     */
    val displayDuration: String
        get() {
            val minutes = (duration.inWholeMinutes % 60).toString().padStart(2, '0')
            val seconds = (duration.inWholeSeconds % 60).toString().padStart(2, '0')
            return "$minutes:$seconds"
        }

    /**
     * 用于 UI 显示的标题——剥离常见音频文件扩展名后缀。
     *
     * 1:1 移植自 song.dart:99-108。酷狗 API 返回的 `songname`/`FileName`
     * 字段有时带 `.mp3`/`.flac` 等后缀，在 UI 显示时应当剥离。原始 [title]
     * 字段保持不变用于搜索/收藏 key 等场景。支持的扩展名：mp3, flac, wav,
     * ape, m4a, ogg, aac, wma, opus（大小写不敏感）。
     */
    val displayName: String
        get() = AUDIO_EXTENSION_PATTERN.replaceFirst(title, "")

    /**
     * 相等性仅比较 [id]（保留 Dart `operator ==` 语义，见类 KDoc）。
     *
     * song.dart:215-221：
     * ```dart
     * bool operator ==(Object other) =>
     *     identical(this, other) ||
     *     other is Song && runtimeType == other.runtimeType && id == other.id;
     * int get hashCode => id.hashCode;
     * ```
     */
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is Song) return false
        return id == other.id
    }

    override fun hashCode(): Int = id.hashCode()

    private companion object {
        /** 与 song.dart:105-106 的 RegExp 等价（大小写不敏感、结尾锚定）。 */
        val AUDIO_EXTENSION_PATTERN = Regex(
            """\.(mp3|flac|wav|ape|m4a|ogg|aac|wma|opus)$""",
            RegexOption.IGNORE_CASE,
        )
    }
}

/// 元数据缺失时使用的占位值。
///
/// **为什么需要统一常量**：项目里有两条产生占位值的路径，字面量曾经不一致——
/// - 在线侧（`KugouSongDetail.toSong`）：[UNKNOWN_ARTIST_PLACEHOLDER]
/// - 本地侧（`local_music_repository` / `audio_scanner`）：[UNKNOWN_ARTIST_PLACEHOLDER_LOCAL]
///
/// 消费方若只比较其中一个，另一条路径就会漏判。实例：歌词检索词守卫曾写
/// `song.artist != '未知艺术家'`，但在线侧的值是 `未知歌手` → 守卫恒真
/// → 检索词退化成「未知歌曲 未知歌手」，歌词匹配质量下降。
///
/// 因此判断「歌手是否未知」一律用 [isUnknownArtist]，不要直接比较字面量。
///
/// 1:1 移植自 song.dart:1-14。
const val UNKNOWN_SONG_TITLE = "未知歌曲"
const val UNKNOWN_ARTIST_PLACEHOLDER = "未知歌手"
const val UNKNOWN_ARTIST_PLACEHOLDER_LOCAL = "未知艺术家"

/**
 * 判断歌手名是否为占位值（同时覆盖在线侧与本地侧两种写法）。
 *
 * 空串也算未知：部分接口返回空字符串而非占位文本。
 *
 * 1:1 移植自 song.dart:16-25。
 */
fun isUnknownArtist(artist: String?): Boolean {
    if (artist == null) return true
    val v = artist.trim()
    return v.isEmpty() ||
        v == UNKNOWN_ARTIST_PLACEHOLDER ||
        v == UNKNOWN_ARTIST_PLACEHOLDER_LOCAL
}
