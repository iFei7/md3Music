package com.md3music.md3music.player.session

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 待执行命令缓冲测试。
 *
 * 核心是两条容易被"优化"掉的性质：
 * 1. FIFO 顺序（双击 play→next 不能被重排或吞掉 play）；
 * 2. 拒收时原序放回（重放中断后不能丢序、不能重复投递）。
 */
class PendingCommandBufferTest {

    @Test
    fun `默认容量与语义常量被钉死`() {
        assertEquals(4, PendingCommandBuffer.DEFAULT_CAPACITY)
    }

    @Test
    fun `按 FIFO 顺序投递`() {
        val buffer = PendingCommandBuffer()
        buffer.offer(PlayerCommand.Play)
        buffer.offer(PlayerCommand.Next)
        buffer.offer(PlayerCommand.Pause)

        val delivered = mutableListOf<PlayerCommand>()
        val count = buffer.drainTo { delivered.add(it); true }

        assertEquals(3, count)
        assertEquals(listOf(PlayerCommand.Play, PlayerCommand.Next, PlayerCommand.Pause), delivered)
        assertTrue(buffer.isEmpty)
    }

    @Test
    fun `双击序列按序保留_play 不被 next 顶掉`() {
        val buffer = PendingCommandBuffer()
        buffer.offer(PlayerCommand.Play)
        buffer.offer(PlayerCommand.Next)

        val delivered = mutableListOf<PlayerCommand>()
        buffer.drainTo { delivered.add(it); true }

        assertEquals(
            "若采用 lite 的「只留最新」，play 会被 next 顶掉；冷启动双击就会只切歌不播放",
            listOf(PlayerCommand.Play, PlayerCommand.Next),
            delivered,
        )
    }

    @Test
    fun `溢出时丢弃最旧并计数`() {
        val buffer = PendingCommandBuffer(capacity = 2)
        assertFalse(buffer.offer(PlayerCommand.Play))
        assertFalse(buffer.offer(PlayerCommand.Next))
        assertTrue("第 3 条触发溢出", buffer.offer(PlayerCommand.Pause))

        assertEquals(1, buffer.droppedCount)
        assertEquals(listOf(PlayerCommand.Next, PlayerCommand.Pause), buffer.snapshot())
    }

    @Test
    fun `单条命令超容量时仍能入队且不残留更旧命令`() {
        val buffer = PendingCommandBuffer(capacity = 2)
        buffer.offer(PlayerCommand.Play)
        buffer.offer(PlayerCommand.Next)
        buffer.offer(PlayerCommand.Pause)
        buffer.offer(PlayerCommand.Stop)
        buffer.offer(PlayerCommand.ToggleFavorite)

        assertEquals(listOf(PlayerCommand.Stop, PlayerCommand.ToggleFavorite), buffer.snapshot())
        assertEquals(3, buffer.droppedCount)
    }

    @Test
    fun `拒收时该条与其后命令原序放回`() {
        val buffer = PendingCommandBuffer()
        buffer.offer(PlayerCommand.Play)
        buffer.offer(PlayerCommand.Next)
        buffer.offer(PlayerCommand.Pause)

        val delivered = mutableListOf<PlayerCommand>()
        val count = buffer.drainTo { command ->
            // 第二条（Next）被拒收
            if (command == PlayerCommand.Next) false
            else {
                delivered.add(command)
                true
            }
        }

        assertEquals(1, count)
        assertEquals(listOf(PlayerCommand.Play), delivered)
        assertEquals(
            "被拒收的 Next 及其后的 Pause 必须原序保留",
            listOf(PlayerCommand.Next, PlayerCommand.Pause),
            buffer.snapshot(),
        )
    }

    @Test
    fun `全拒收时队列保持不变且不重复投递`() {
        val buffer = PendingCommandBuffer()
        buffer.offer(PlayerCommand.Play)
        buffer.offer(PlayerCommand.Next)

        val attempts = mutableListOf<PlayerCommand>()
        val count = buffer.drainTo { attempts.add(it); false }

        assertEquals(0, count)
        assertEquals("只应尝试投递队首一次", listOf(PlayerCommand.Play), attempts)
        assertEquals(listOf(PlayerCommand.Play, PlayerCommand.Next), buffer.snapshot())
    }

    @Test
    fun `清空后计数与内容归零`() {
        val buffer = PendingCommandBuffer(capacity = 1)
        buffer.offer(PlayerCommand.Play)
        buffer.offer(PlayerCommand.Next)
        assertEquals(1, buffer.size)
        buffer.clear()
        assertTrue(buffer.isEmpty)
        assertEquals(0, buffer.droppedCount)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `容量非法时构造失败`() {
        PendingCommandBuffer(capacity = 0)
    }
}
