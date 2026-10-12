package com.gracemusic.player.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * [safePlaybackErrorMessage] 的移植锁测试。
 *
 * 对标 lib/providers/player_provider.dart:120-133 的 switch 表达式。
 *
 * 本测试的核心价值是**钉死六个字面量**：这些键既是发送方
 * （`_resolveAndPlayCurrentSongImpl` 等处）写出的原文，也是映射表的键，
 * 任何一侧被「顺手修正」（尤其是第三项中间那个空格）都会让文案静默退化成
 * 兜底的「播放失败，请重试」——不会报错，只会让用户看到错误的提示。
 */
class PlaybackErrorMessagesTest {

    @Test
    fun `空值与非空字符串之外的输入返回 null`() {
        assertNull(safePlaybackErrorMessage(null))
        assertNull(safePlaybackErrorMessage(""))
    }

    @Test
    fun `六条已知错误各自映射到专属文案`() {
        assertEquals("该听书章节需要单独购买", safePlaybackErrorMessage("该章节为 听书VIP单独付费内容"))
        assertEquals("无法获取播放链接，请重试", safePlaybackErrorMessage("无法获取播放链接"))
        assertEquals("播放失败，请检查网络后重试", safePlaybackErrorMessage("播放失败，请检查网络"))
        assertEquals("播放恢复失败，请重试", safePlaybackErrorMessage("播放恢复失败，请稍后重试"))
        assertEquals("无法获取云盘播放链接，请重试", safePlaybackErrorMessage("无法获取云盘播放链接"))
        assertEquals("播放器尚未就绪，请重试", safePlaybackErrorMessage("音频引擎尚未就绪"))
    }

    @Test
    fun `听书文案的键含一个空格_不可顺手修正`() {
        // 这是 Dart 字面量原样（'该章节为 听书VIP单独付费内容'：为 与 听书 之间一个空格）。
        // 若把键「修正」成不带空格，映射失效 → 退化为兜底文案。
        assertEquals("该听书章节需要单独购买", safePlaybackErrorMessage("该章节为 听书VIP单独付费内容"))
        assertEquals("播放失败，请重试", safePlaybackErrorMessage("该章节为听书VIP单独付费内容"))
    }

    @Test
    fun `未知错误一律折叠为兜底文案_不泄漏原始串`() {
        assertEquals("播放失败，请重试", safePlaybackErrorMessage("PlatformException(foo)"))
        assertEquals("播放失败，请重试", safePlaybackErrorMessage("http://cdn.example.com/a.mp3 404"))
        assertEquals("播放失败，请重试", safePlaybackErrorMessage("播放失败，请检查网络 ")) // 尾空格不匹配
        assertEquals("播放失败，请重试", safePlaybackErrorMessage("无法获取播放链接，请重试")) // 已是展示文案 → 再收敛
    }

    @Test
    fun `展示文案再收敛时落到兜底_不会原样穿透`() {
        // 注意：本函数**不是**严格幂等的——已映射出的展示文案并非映射表的键，
        // 二次调用会落到兜底。真正要保的性质是「原始串永不穿透到 UI」。
        val shown = safePlaybackErrorMessage("无法获取播放链接")
        assertEquals("无法获取播放链接，请重试", shown)
        assertEquals("播放失败，请重试", safePlaybackErrorMessage(shown))
    }
}
