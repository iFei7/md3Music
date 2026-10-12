package com.md3music.md3music.player.session

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 会话注册点测试。
 *
 * 覆盖的是**冷启动唤醒**这条最容易静默失效的链路：耳机按键拉起进程 → 播放域恢复中
 * → 命令必须被暂存并在就绪后按序重放，而不是丢失。
 */
class PlaybackSessionRegistryTest {

    /** 可编程的假桥：能模拟"未就绪"（全拒收）与"按序放行 N 条"。 */
    private class FakeBridge(
        private val acceptPolicy: (PlayerCommand) -> Boolean = { true },
    ) : PlaybackSessionBridge {
        val received = mutableListOf<PlayerCommand>()
        val attempts = mutableListOf<PlayerCommand>()

        override fun dispatch(command: PlayerCommand): Boolean {
            attempts.add(command)
            if (!acceptPolicy(command)) return false
            received.add(command)
            return true
        }
    }

    @Test
    fun `未注册桥时命令入缓冲且未派发`() {
        val registry = PlaybackSessionRegistry()
        assertFalse(registry.isReady)

        assertEquals(DispatchOutcome.BUFFERED, registry.dispatch(PlayerCommand.Play))
        assertEquals(1, registry.pendingCount)
    }

    @Test
    fun `注册桥后按序重放缓冲命令`() {
        val registry = PlaybackSessionRegistry()
        registry.dispatch(PlayerCommand.Play)
        registry.dispatch(PlayerCommand.Next)

        val bridge = FakeBridge()
        assertEquals(2, registry.attach(bridge))

        assertEquals(listOf(PlayerCommand.Play, PlayerCommand.Next), bridge.received)
        assertEquals(0, registry.pendingCount)
        assertTrue(registry.isReady)
    }

    @Test
    fun `就绪后命令直投不再入缓冲`() {
        val registry = PlaybackSessionRegistry()
        val bridge = FakeBridge()
        registry.attach(bridge)

        assertEquals(DispatchOutcome.DISPATCHED, registry.dispatch(PlayerCommand.Pause))
        assertEquals(listOf(PlayerCommand.Pause), bridge.received)
        assertEquals(0, registry.pendingCount)
    }

    @Test
    fun `桥暂时拒收时命令回落缓冲而非丢弃`() {
        val registry = PlaybackSessionRegistry()
        val bridge = FakeBridge { false } // 已注册但仍在恢复队列
        registry.attach(bridge)

        assertEquals(DispatchOutcome.BUFFERED, registry.dispatch(PlayerCommand.Play))
        assertEquals(1, registry.pendingCount)
        assertEquals(
            "入缓冲前必须先真实尝试投递一次，否则「已就绪但暂时繁忙」的桥永远收不到直投",
            listOf(PlayerCommand.Play),
            bridge.attempts,
        )
        assertTrue(bridge.received.isEmpty())
    }

    @Test
    fun `重放期间被拒收的命令保持原序留在缓冲`() {
        val registry = PlaybackSessionRegistry()
        registry.dispatch(PlayerCommand.Play)
        registry.dispatch(PlayerCommand.Next)
        registry.dispatch(PlayerCommand.Pause)

        // 模拟桥"一次只能吃一条"的收敛过程
        var quota = 1
        val bridge = FakeBridge { quota-- > 0 }

        assertEquals(1, registry.attach(bridge))
        assertEquals(listOf(PlayerCommand.Play), bridge.received)
        assertEquals(2, registry.pendingCount)

        quota = 2
        assertEquals(2, registry.replayPending())
        assertEquals(
            listOf(PlayerCommand.Play, PlayerCommand.Next, PlayerCommand.Pause),
            bridge.received,
        )
        assertEquals(0, registry.pendingCount)
    }

    @Test
    fun `注销桥后新命令重新入缓冲_不沿用旧桥`() {
        val registry = PlaybackSessionRegistry()
        val bridge = FakeBridge()
        registry.attach(bridge)
        registry.detach(bridge)

        assertFalse(registry.isReady)
        assertEquals(DispatchOutcome.BUFFERED, registry.dispatch(PlayerCommand.Stop))
        assertEquals("旧桥不得再收到命令", 0, bridge.received.size)
    }

    @Test
    fun `注销非当前桥是空操作`() {
        val registry = PlaybackSessionRegistry()
        val bridge = FakeBridge()
        registry.attach(bridge)
        registry.detach(FakeBridge())

        assertTrue("注销另一个实例不得把当前桥摘掉", registry.isReady)
        assertEquals(DispatchOutcome.DISPATCHED, registry.dispatch(PlayerCommand.Play))
    }

    @Test
    fun `注销后缓冲被刻意保留_重新注册时一并重放`() {
        val registry = PlaybackSessionRegistry()
        val first = FakeBridge()
        registry.attach(first)
        registry.detach(first)
        registry.dispatch(PlayerCommand.Play)

        val second = FakeBridge()
        assertEquals(1, registry.attach(second))
        assertEquals(listOf(PlayerCommand.Play), second.received)
    }

    @Test
    fun `显式清空丢弃全部缓冲`() {
        val registry = PlaybackSessionRegistry()
        registry.dispatch(PlayerCommand.Play)
        registry.dispatch(PlayerCommand.Next)
        registry.clearPending()

        assertEquals(0, registry.pendingCount)
        val bridge = FakeBridge()
        assertEquals(0, registry.attach(bridge))
        assertTrue(bridge.received.isEmpty())
    }

    @Test
    fun `无桥时重放是空操作`() {
        val registry = PlaybackSessionRegistry()
        assertEquals(0, registry.replayPending())
    }
}
