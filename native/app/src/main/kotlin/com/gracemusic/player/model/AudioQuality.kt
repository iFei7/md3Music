package com.gracemusic.player.model

/**
 * 音质档位（设置项取值域，也是播放请求发给酷狗 API 的码值）。
 *
 * 1:1 移植自 lib/providers/player_provider.dart:96-107 的 enum AudioQuality。
 * [value] 为 SharedPreferences / API 使用的持久化值，[label] 为设置页展示名。
 */
enum class AudioQuality(val value: String, val label: String) {
    /** 标准音质（API 码 128）。 */
    STANDARD("128", "标准音质"),

    /** 高音质（API 码 320；早期版本误用 'hq'，遗留值映射见 [LEGACY_QUALITY_MAP]）。 */
    HIGH("320", "高音质"),

    /** 无损音质（flac）。 */
    FLAC("flac", "无损音质"),

    /** Hi-Res（API 码 high）。 */
    HIRES("high", "Hi-Res"),

    /** 蝰蛇母带（等级 101，需实验开关 + VIP；关闭实验开关时请求侧钳回 Hi-Res）。 */
    VIPER("viper_tape", "蝰蛇母带"),
    ;

    companion object {
        /**
         * 旧版本 SharedPreferences 中存储的音质值 → 当前 [AudioQuality.value] 映射。
         * 升级后首次读取时自动转换，避免遗留值导致回退到标准音质。
         *
         * 1:1 移植自 player_provider.dart:109-118（_legacyQualityMap）：
         * 注意高音质的 API 码是 '320'（KuGou SongQuality 合法值），
         * 早期版本误用 'hq'，这里把遗留的 'hq' 映射到 '320'。
         */
        val LEGACY_QUALITY_MAP: Map<String, String> = mapOf(
            "hq" to "320",
            "sq" to "flac",
            "standard" to "128",
            "hires" to "high",
        )

        /**
         * 从持久化值解析档位（含遗留值转换）。
         * 无法识别（null / 空串 / 未知值）时回落 [STANDARD]，与 Dart
         * `AudioQuality.values.firstWhere(..., orElse: standard)` 一致
         * （player_provider.dart:1229-1234）。
         */
        fun fromStoredValue(value: String?): AudioQuality {
            val mapped = LEGACY_QUALITY_MAP[value] ?: value
            return entries.firstOrNull { it.value == mapped } ?: STANDARD
        }
    }
}

/**
 * 连接类型（对齐 connectivity_plus 的 ConnectivityResult 取值子集）。
 *
 * 平台探测不在本文件内：Android 侧由 ConnectivityManager 拿到系统连接后
 * 归一为 [NetworkTransport] 列表传入（播放器状态层 P1-5 挂点），本文件只
 * 保留平台无关的分类纯函数，便于单测。
 */
enum class NetworkTransport {
    WIFI,
    CELLULAR,
    ETHERNET,
    VPN,
    BLUETOOTH,
    OTHER,

    /** 无连接。 */
    NONE,
}

/**
 * 连接列表是否按「WiFi 类」处理：只要不含移动数据即按 WiFi 处理
 * （覆盖 wifi / ethernet / vpn / bluetooth / other / none）。
 *
 * 1:1 移植自 player_provider.dart:1063-1066：
 * ```dart
 * static bool _resultsAreWifi(List<ConnectivityResult> results) =>
 *     !results.contains(ConnectivityResult.mobile);
 * ```
 * 与 _detectIsWifi 的失败回退（player_provider.dart:1052-1061：探测失败按
 * WiFi）叠加后，「无连接/探测失败 → WiFi 分支」成为默认回退路径。
 */
fun isWifiLikeTransports(transports: List<NetworkTransport>): Boolean =
    !transports.contains(NetworkTransport.CELLULAR)

/**
 * 按当前网络解析生效音质——player_provider.dart:1217-1239
 * `_loadQualityForNetwork` 的平台无关核心（仓库读取与状态写回由播放器
 * 状态层负责，ConnectivityManager 探测同样留在平台侧）。
 *
 * 纯函数，语义与 Dart 逐行对齐：
 * 1. 遗留值转换：hq→320, sq→flac, standard→128, hires→high
 *    （player_provider.dart:1221-1222）；
 * 2. 实验开关关闭时蝰蛇母带钳回 Hi-Res（player_provider.dart:1223-1228，
 *    注意只钳生效值、不改写存储值）；
 * 3. 按生效值解析档位，无法识别回落标准音质。
 *
 * 第二次进入 [AudioQuality.fromStoredValue] 是幂等的：遗留键映射产物
 * （320 / flac / 128 / high）均不再是遗留键，不会二次转换。
 *
 * @param storedValue 仓库按当前网络读出的持久化值（getQualityForNetwork(isWifi)）
 * @param viperTapeEnabled 蝰蛇母带实验开关（getViperTapeQualityEnabled）
 */
fun resolveQualityForNetwork(
    storedValue: String?,
    viperTapeEnabled: Boolean,
): AudioQuality {
    val mapped = AudioQuality.LEGACY_QUALITY_MAP[storedValue] ?: storedValue
    val effective =
        if (mapped == AudioQuality.VIPER.value && !viperTapeEnabled) {
            AudioQuality.HIRES.value
        } else {
            mapped
        }
    return AudioQuality.fromStoredValue(effective)
}
