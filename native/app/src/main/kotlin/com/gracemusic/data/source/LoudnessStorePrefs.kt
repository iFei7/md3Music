package com.gracemusic.data.source

import android.content.SharedPreferences
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.put

/**
 * [LoudnessStore] 的 SharedPreferences 实现（T-P1-05，B 侧）。
 *
 * 对位 lite `kugou_models.dart:16,40-50`：SP key `kugou_url_loudness`，
 * 值为 JSON 数组 `[{"u":url,"l":lufs,"p":peak}]`；写前截前
 * [MAX_PERSIST_ENTRIES] 条（lite `:44-47` take(_kugouLoudnessMax)）。
 * 落盘用 `apply()` 异步写——调用方（[LoudnessCache.remember]）同步调本类，
 * 不额外起协程（台本执行步骤 3：save 异步性由 SP apply 提供）。
 *
 * 解析逐条容错（对位 lite `:28-36`：`item is! Map continue`、空 url / 非数值
 * 跳过）：任何一条损坏只丢弃该条，整个文件损坏返回空表，不崩溃。
 */
class LoudnessStorePrefs(private val prefs: SharedPreferences) : LoudnessStore {

    override fun load(): List<Triple<String, Double, Double?>> {
        val raw: String? = prefs.getString(KEY, null)
        return parseLoudnessEntries(raw ?: "")
    }

    override fun save(entries: List<Triple<String, Double, Double?>>) {
        val json: String = buildJsonArray {
            entries.take(MAX_PERSIST_ENTRIES).forEach { entry ->
                val url: String = entry.first
                val lufs: Double = entry.second
                val peak: Double? = entry.third
                addJsonObject {
                    put("u", url)
                    put("l", lufs)
                    put("p", peak)
                }
            }
        }.toString()
        prefs.edit().putString(KEY, json).apply()
    }

    companion object {
        /** SP key，与 lite `_kugouLoudnessPrefsKey` 一致（kugou_models.dart:16）。 */
        const val KEY: String = "kugou_url_loudness"

        /** 持久化条数上限，与 lite `_kugouLoudnessMax` 一致（kugou_models.dart:17）。 */
        const val MAX_PERSIST_ENTRIES: Int = 300

        /**
         * 把持久化 JSON 字符串解析为 (url, lufs, peak) 列表。
         *
         * 容错规则（对位 lite warmLoudnessCache :28-36）：
         * - 非法 JSON / 空串 → 空表；
         * - 元素非对象、`u` 缺失/非字符串/空串、`l` 缺失/非数值/非有限 → 丢弃该条；
         * - `p` 缺失或非数值 → 按 null。
         * 纯函数，便于纯 JVM 单测覆盖损坏输入（不依赖 Robolectric）。
         */
        fun parseLoudnessEntries(raw: String): List<Triple<String, Double, Double?>> {
            if (raw.isBlank()) return emptyList()
            return try {
                Json.parseToJsonElement(raw).jsonArray.mapNotNull { element ->
                    val obj: JsonObject = element as? JsonObject ?: return@mapNotNull null
                    val url: String = (obj["u"] as? JsonPrimitive)?.takeIf { it.isString }?.content
                        ?: return@mapNotNull null
                    if (url.isEmpty()) return@mapNotNull null
                    val lufs: Double = (obj["l"] as? JsonPrimitive)?.doubleOrNull ?: return@mapNotNull null
                    if (!lufs.isFinite()) return@mapNotNull null
                    val peak: Double? = (obj["p"] as? JsonPrimitive)?.doubleOrNull
                    Triple(url, lufs, peak)
                }
            } catch (_: Exception) {
                emptyList()
            }
        }
    }
}
