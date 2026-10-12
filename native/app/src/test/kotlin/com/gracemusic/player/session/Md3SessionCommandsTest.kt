package com.gracemusic.player.session

import android.app.Application
import android.os.Bundle
import androidx.media3.session.SessionCommand
import com.gracemusic.R
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * 会话命令与按钮构造测试。
 *
 * 其中 [Md3SessionCommands.CUSTOM_ACTION_TOGGLE_FAVORITE] 是**协议值**——它进入
 * SystemUI 按钮点击 → 会话命令回传链路，本测试把它钉死为 GraceMusic 的命名空间
 * （`com.gracemusic.*`），防止后续"顺手改个更规范的名字"导致已投递到 SystemUI
 * 的按钮点击失效。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class Md3SessionCommandsTest {

    @Test
    fun `收藏命令标识被钉死为 GraceMusic 协议值`() {
        assertEquals("com.gracemusic.toggle_favorite", Md3SessionCommands.CUSTOM_ACTION_TOGGLE_FAVORITE)
    }

    @Test
    fun `可用会话命令集合包含收藏命令`() {
        val commands = Md3SessionCommands.availableSessionCommands()
        assertTrue(
            "未声明可用命令时，media3 会把自定义按钮从通知 customLayout 中过滤掉",
            commands.contains(Md3SessionCommands.toggleFavoriteCommand()),
        )
    }

    @Test
    fun `命令识别只认收藏命令`() {
        assertTrue(Md3SessionCommands.isToggleFavorite(Md3SessionCommands.toggleFavoriteCommand()))
        assertFalse(
            Md3SessionCommands.isToggleFavorite(SessionCommand("com.gracemusic.something_else", Bundle())),
        )
        assertFalse("null 不得被判为收藏命令", Md3SessionCommands.isToggleFavorite(null))
    }

    @Test
    fun `收藏按钮图标随收藏态切换且始终可用`() {
        val onButton = Md3SessionCommands.buildFavoriteButton(
            isFavorited = true,
            favoriteOnIconRes = R.drawable.ic_favorite_on,
            favoriteOffIconRes = R.drawable.ic_favorite_off,
        )
        assertEquals(R.drawable.ic_favorite_on, onButton.iconResId)
        assertTrue(onButton.isEnabled)
        assertEquals("收藏", onButton.displayName)
        assertEquals(
            "按钮必须绑定自定义命令，否则点击不会经 onCustomCommand 回传",
            Md3SessionCommands.CUSTOM_ACTION_TOGGLE_FAVORITE,
            onButton.sessionCommand?.customAction,
        )

        val offButton = Md3SessionCommands.buildFavoriteButton(
            isFavorited = false,
            favoriteOnIconRes = R.drawable.ic_favorite_on,
            favoriteOffIconRes = R.drawable.ic_favorite_off,
        )
        assertEquals(R.drawable.ic_favorite_off, offButton.iconResId)
    }
}
