package com.md3music.md3music.player.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [AudioQuality] 档位表、遗留值映射与网络分流选择的移植锁测试。
 *
 * 场景对标 lib/providers/player_provider.dart：
 * - 96-107 行 enum AudioQuality 五档 value / label；
 * - 109-118 行 _legacyQualityMap 遗留值映射；
 * - 1217-1239 行 _loadQualityForNetwork 的钳回与回落；
 * - 1063-1066 行 _resultsAreWifi 的网络分类。
 */
class AudioQualityTest {

    @Test
    fun `五档 value 与 label 与 Dart 逐一一致`() {
        val expected = mapOf(
            "128" to "标准音质",
            "320" to "高音质",
            "flac" to "无损音质",
            "high" to "Hi-Res",
            "viper_tape" to "蝰蛇母带",
        )
        assertEquals(5, AudioQuality.entries.size)
        assertEquals(expected, AudioQuality.entries.associate { it.value to it.label })
    }

    @Test
    fun `新值直通解析`() {
        assertEquals(AudioQuality.STANDARD, AudioQuality.fromStoredValue("128"))
        assertEquals(AudioQuality.HIGH, AudioQuality.fromStoredValue("320"))
        assertEquals(AudioQuality.FLAC, AudioQuality.fromStoredValue("flac"))
        assertEquals(AudioQuality.HIRES, AudioQuality.fromStoredValue("high"))
        assertEquals(AudioQuality.VIPER, AudioQuality.fromStoredValue("viper_tape"))
    }

    @Test
    fun `遗留值映射到新档位`() {
        // hq→320（高音质早期误用码）、sq→flac、standard→128、hires→high
        assertEquals(AudioQuality.HIGH, AudioQuality.fromStoredValue("hq"))
        assertEquals(AudioQuality.FLAC, AudioQuality.fromStoredValue("sq"))
        assertEquals(AudioQuality.STANDARD, AudioQuality.fromStoredValue("standard"))
        assertEquals(AudioQuality.HIRES, AudioQuality.fromStoredValue("hires"))
    }

    @Test
    fun `无法识别的值回落标准音质`() {
        assertEquals(AudioQuality.STANDARD, AudioQuality.fromStoredValue(null))
        assertEquals(AudioQuality.STANDARD, AudioQuality.fromStoredValue(""))
        assertEquals(AudioQuality.STANDARD, AudioQuality.fromStoredValue("unknown"))
        // 大小写敏感：'HQ' 不是遗留键
        assertEquals(AudioQuality.STANDARD, AudioQuality.fromStoredValue("HQ"))
    }

    @Test
    fun `遗留映射表内容锁定`() {
        assertEquals(
            mapOf(
                "hq" to "320",
                "sq" to "flac",
                "standard" to "128",
                "hires" to "high",
            ),
            AudioQuality.LEGACY_QUALITY_MAP,
        )
    }

    @Test
    fun `网络分流选择_实验开关开启时蝰蛇母带生效`() {
        assertEquals(
            AudioQuality.VIPER,
            resolveQualityForNetwork("viper_tape", viperTapeEnabled = true),
        )
    }

    @Test
    fun `网络分流选择_实验开关关闭时蝰蛇母带钳回 HiRes`() {
        assertEquals(
            AudioQuality.HIRES,
            resolveQualityForNetwork("viper_tape", viperTapeEnabled = false),
        )
        // 钳回只影响生效值：其他档位不受开关影响
        assertEquals(
            AudioQuality.HIRES,
            resolveQualityForNetwork("high", viperTapeEnabled = false),
        )
        assertEquals(
            AudioQuality.FLAC,
            resolveQualityForNetwork("sq", viperTapeEnabled = false),
        )
    }

    @Test
    fun `网络分流选择_遗留值先转换再钳回`() {
        assertEquals(AudioQuality.HIGH, resolveQualityForNetwork("hq", viperTapeEnabled = true))
        assertEquals(AudioQuality.FLAC, resolveQualityForNetwork("sq", viperTapeEnabled = false))
        assertEquals(AudioQuality.STANDARD, resolveQualityForNetwork("standard", viperTapeEnabled = true))
        assertEquals(AudioQuality.HIRES, resolveQualityForNetwork("hires", viperTapeEnabled = true))
    }

    @Test
    fun `网络分流选择_空值与未知值回落标准音质`() {
        assertEquals(AudioQuality.STANDARD, resolveQualityForNetwork(null, viperTapeEnabled = true))
        assertEquals(AudioQuality.STANDARD, resolveQualityForNetwork("", viperTapeEnabled = false))
        assertEquals(AudioQuality.STANDARD, resolveQualityForNetwork("garbage", viperTapeEnabled = true))
    }

    @Test
    fun `WiFi 类连接判定_不含移动数据即按 WiFi 处理`() {
        assertTrue(isWifiLikeTransports(listOf(NetworkTransport.WIFI)))
        assertTrue(isWifiLikeTransports(listOf(NetworkTransport.ETHERNET)))
        assertTrue(isWifiLikeTransports(listOf(NetworkTransport.VPN)))
        assertTrue(isWifiLikeTransports(listOf(NetworkTransport.BLUETOOTH)))
        assertTrue(isWifiLikeTransports(listOf(NetworkTransport.OTHER)))
        // 无连接按 WiFi 处理（_detectIsWifi 探测失败同样回退 true）
        assertTrue(isWifiLikeTransports(listOf(NetworkTransport.NONE)))
        assertTrue(isWifiLikeTransports(emptyList()))
    }

    @Test
    fun `WiFi 类连接判定_含移动数据即按移动网络处理`() {
        assertFalse(isWifiLikeTransports(listOf(NetworkTransport.CELLULAR)))
        assertFalse(isWifiLikeTransports(listOf(NetworkTransport.WIFI, NetworkTransport.CELLULAR)))
        assertFalse(isWifiLikeTransports(listOf(NetworkTransport.NONE, NetworkTransport.CELLULAR)))
    }
}
