package com.gracemusic.player.offline

import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * [OfflineAdvancePolicy] 纯函数单测（无 I/O、无协程、无 Android 语义依赖）。
 *
 * 覆盖策略契约的**边界**与**选择语义**；「候选下标怎么来」由
 * `PlaybackQueue.nextCandidateIndices` 的既有测试保证，本类只喂显式候选列表，
 * 以证明策略本身不含任何索引算术（交接铁律 §4-7）。
 */
@RunWith(RobolectricTestRunner::class)
class OfflineAdvancePolicyTest {

    @Test
    fun `空候选列表_一律停止`() {
        val decision = OfflineAdvancePolicy.choose(emptyList()) { true }

        assertEquals(OfflineAdvancePolicy.Decision.Stop, decision)
    }

    @Test
    fun `候选全未缓存_停止`() {
        val decision = OfflineAdvancePolicy.choose(listOf(1, 2, 3)) { false }

        assertEquals(OfflineAdvancePolicy.Decision.Stop, decision)
    }

    @Test
    fun `首个已缓存即选中`() {
        val decision = OfflineAdvancePolicy.choose(listOf(1, 2, 3)) { it == 1 }

        assertEquals(OfflineAdvancePolicy.Decision.Play(1), decision)
    }

    @Test
    fun `跳过连续未缓存后落到首个已缓存`() {
        val probed = mutableListOf<Int>()
        val decision = OfflineAdvancePolicy.choose(listOf(1, 2, 3, 4)) {
            probed += it
            it == 4
        }

        assertEquals(OfflineAdvancePolicy.Decision.Play(4), decision)
        assertEquals("必须按序探测到命中为止", listOf(1, 2, 3, 4), probed)
    }

    @Test
    fun `命中即返回_不再继续探测后续候选`() {
        val probed = mutableListOf<Int>()
        OfflineAdvancePolicy.choose(listOf(1, 2, 3)) {
            probed += it
            it == 2
        }

        assertEquals("命中后不得再探测", listOf(1, 2), probed)
    }

    @Test
    fun `负下标被跳过_不参与命中判定`() {
        val probed = mutableListOf<Int>()
        val decision = OfflineAdvancePolicy.choose(listOf(-1, 0)) {
            probed += it
            it == 0
        }

        assertEquals(OfflineAdvancePolicy.Decision.Play(0), decision)
        assertEquals("负下标不得进入谓词", listOf(0), probed)
    }

    @Test
    fun `仅负下标候选_停止`() {
        val decision = OfflineAdvancePolicy.choose(listOf(-1, -2)) { true }

        assertEquals(OfflineAdvancePolicy.Decision.Stop, decision)
    }

    @Test
    fun `候选顺序即优先级_不重排`() {
        // 候选列表是「优先级序」（由调用方按队列语义给出）；策略不得重排或挑最大/最小。
        val decision = OfflineAdvancePolicy.choose(listOf(5, 1, 3)) { it == 1 || it == 5 }

        assertEquals("必须取列表中最靠前的命中项", OfflineAdvancePolicy.Decision.Play(5), decision)
    }

    @Test
    fun `单元素候选_已缓存则选中_未缓存则停止`() {
        assertEquals(
            OfflineAdvancePolicy.Decision.Play(0),
            OfflineAdvancePolicy.choose(listOf(0)) { true },
        )
        assertEquals(
            OfflineAdvancePolicy.Decision.Stop,
            OfflineAdvancePolicy.choose(listOf(0)) { false },
        )
    }
}
