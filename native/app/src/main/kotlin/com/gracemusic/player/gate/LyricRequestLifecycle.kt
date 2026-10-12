package com.gracemusic.player.gate

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.launch
import kotlin.time.Duration
import kotlin.time.Duration.Companion.ZERO
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.milliseconds

/**
 * 歌词查询结果分类。只有确认接口成功返回"没有候选"时才使用 [NOT_FOUND]。
 *
 * 1:1 移植自 lib/services/kugou_api/lyric_lookup_result.dart:4-10。
 */
enum class LyricLookupStatus {
    FOUND,
    NOT_FOUND,
    TRANSIENT_FAILURE,
    INVALID_DATA,
    CANCELED,
}

/**
 * 歌词请求身份。展示代次不在此键中，避免因页面重建破坏相同请求合并。
 *
 * 1:1 移植自 lib/providers/lyric_request_lifecycle.dart:4-34。
 *
 * 语义契约（与 Dart 逐值一致）：
 * - 三字段 identity / format / query 全部参与相等性判定；
 * - [forRequest] 工厂对三个入参做 `trim().lowercase()` 归一化
 *   （Dart `toLowerCase()` 为 locale 无关映射，Kotlin `lowercase()` 一致）；
 *   songName 为 null 时 query 归一为空串。
 */
data class LyricRequestKey(
    val identity: String,
    val format: String,
    val query: String,
) {
    companion object {
        fun forRequest(
            identity: String,
            format: String,
            songName: String?,
        ): LyricRequestKey = LyricRequestKey(
            identity = identity.trim().lowercase(),
            format = format.trim().lowercase(),
            query = songName?.trim()?.lowercase() ?: "",
        )
    }
}

/**
 * 同一歌词身份只保留一个网络/持久化读取任务。
 *
 * 1:1 移植自 lib/providers/lyric_request_lifecycle.dart:37-51。
 *
 * 语义契约（与 Dart 逐值一致）：
 * - 同键并发调用返回同一个 [Deferred] 实例（Dart `identical`），load 只执行一次；
 * - 任务完成（成功或失败）后移除占位（Dart `whenComplete`），且仅当占位仍
 *   属于该任务时才移除（identity 校验，防旧任务误释新任务）；
 * - 失败同样移除占位，瞬时失败可再次重试。
 *
 * 与 Dart 的差异：Dart 的 `Future` 由语言事件循环驱动；Kotlin 侧改为协程
 * [Deferred] + 注入的 [scope]（调用方管理生命周期，测试可注入虚拟时间
 * TestDispatcher，不 sleep）。`run` 保持同步非挂起函数，与 Dart 签名行为一致。
 */
class LyricRequestDeduplicator<T>(private val scope: CoroutineScope) {
    private val inFlight = HashMap<LyricRequestKey, Deferred<T>>()

    fun run(key: LyricRequestKey, load: suspend () -> T): Deferred<T> = synchronized(inFlight) {
        inFlight[key]?.let { return@synchronized it }
        // 先占位再启动：保证完成回调执行时占位必已写入（ Dart 单线程事件循环
        // 的等价保证；协程下 load 可能在其它线程瞬时完成，故不能先启动后占位）。
        val request = CompletableDeferred<T>()
        inFlight[key] = request
        scope.launch {
            try {
                request.complete(load())
            } catch (e: Throwable) {
                request.completeExceptionally(e)
            }
        }
        request.invokeOnCompletion {
            synchronized(inFlight) {
                if (inFlight[key] === request) inFlight.remove(key)
            }
        }
        request
    }
}

/**
 * 仅缓存"已确认无歌词"的短期结果，不缓存网络错误或无效响应。
 *
 * 1:1 移植自 lib/providers/lyric_request_lifecycle.dart:54-86。
 *
 * 语义契约（与 Dart 逐值一致）：
 * - [contains] 命中即刷新 LRU 顺序（Dart：remove 后重新 put 到队尾）；
 *   过期条目（now >= expiresAt，闭边界）在访问时被剔除并返回 false；
 * - [put] 在 capacity <= 0 或 ttl <= 0 时为 no-op；写入后按容量
 *   从队首逐出（LinkedHashMap 插入序 = Dart Map 迭代序）；
 * - 时钟经构造函数注入（epoch 毫秒），默认 [System.currentTimeMillis]。
 */
class LyricNotFoundCache(
    val ttl: Duration,
    val capacity: Int,
    private val clock: () -> Long = { System.currentTimeMillis() },
) {
    private val entries = LinkedHashMap<LyricRequestKey, Long>()

    fun contains(key: LyricRequestKey): Boolean {
        val expiresAt = entries.remove(key) ?: return false
        if (clock() >= expiresAt) return false
        entries[key] = expiresAt
        return true
    }

    fun put(key: LyricRequestKey) {
        if (capacity <= 0 || ttl <= ZERO) return
        entries.remove(key)
        entries[key] = clock() + ttl.inWholeMilliseconds
        while (entries.size > capacity) {
            val oldest = entries.keys.first()
            entries.remove(oldest)
        }
    }

    fun remove(key: LyricRequestKey) {
        entries.remove(key)
    }

    fun clear() {
        entries.clear()
    }
}

/**
 * 桌面歌词按结果类型退避；不确定失败短退避，确认无词沿用负缓存 TTL。
 *
 * 1:1 移植自 lib/providers/lyric_request_lifecycle.dart:89-102。
 *
 * 语义契约（与 Dart 逐值一致）：
 * - NOT_FOUND → 5 分钟（负缓存冷却）；
 * - TRANSIENT_FAILURE / INVALID_DATA → 250ms 起指数退避，
 *   指数 = (failureCount - 1).clamp(0, 6)，毫秒值 clamp 到 [250, 10000]；
 * - 其余状态 → ZERO（不安排重试）。
 */
object LyricRetryPolicy {
    fun delayFor(status: LyricLookupStatus, failureCount: Int): Duration {
        if (status == LyricLookupStatus.NOT_FOUND) {
            return 5.minutes
        }
        if (status == LyricLookupStatus.TRANSIENT_FAILURE ||
            status == LyricLookupStatus.INVALID_DATA
        ) {
            val exponent = (failureCount - 1).coerceIn(0, 6)
            val delayMillis = (250 * (1 shl exponent)).coerceIn(250, 10_000)
            return delayMillis.milliseconds
        }
        return ZERO
    }
}
