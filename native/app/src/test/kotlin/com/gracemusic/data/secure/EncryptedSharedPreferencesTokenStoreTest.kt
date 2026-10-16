package com.gracemusic.data.secure

import android.app.Application
import android.content.Context
import android.os.Looper
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.File

/**
 * [EncryptedSharedPreferencesTokenStore] 行为测试（T-P2-04）。
 *
 * ## 运行前提
 * - `EncryptedSharedPreferences` 需要 Android 运行时 → `@RunWith(RobolectricTestRunner::class)`；
 * - Robolectric 不支持 Android Keystore → [FakeAndroidKeyStoreProvider] 提供内存版
 *   「AndroidKeyStore」provider，使 security-crypto 的真实加解密链路可在 JVM 端到端执行；
 * - 每个测试方法 `@Before` 清空 shared_prefs 目录与假 Keystore（Robolectric 同一
 *   测试类内 dataDir 路径固定，SharedPreferences 文件会跨方法残留）。
 *
 * ## 断言口径
 * 一律断言**行为**（读回值 / 文件内容 / 异常不抛出），不断言「方法被调用」。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class EncryptedSharedPreferencesTokenStoreTest {

    private lateinit var context: Context

    private lateinit var store: EncryptedSharedPreferencesTokenStore

    @Before
    fun setUp() {
        FakeAndroidKeyStoreProvider.ensureInstalled()
        FakeAndroidKeyStoreProvider.reset()
        context = RuntimeEnvironment.getApplication()
        // 清空 shared_prefs 目录：保证测试方法间隔离。
        File(context.filesDir.parentFile, "shared_prefs").listFiles()?.forEach { it.delete() }
        store = EncryptedSharedPreferencesTokenStore(context)
    }

    // ------------------------------------------------------------------
    // 1. round-trip
    // ------------------------------------------------------------------

    @Test
    fun `保存后可原样读回凭证_逐字段相等`() = runTest {
        val credentials = KugouCredentials(
            userid = "123456",
            token = "TOKEN_ROUNDTRIP_A",
            vipToken = "VIP_ROUNDTRIP_B",
        )
        store.save(credentials)

        val loaded = store.load("123456")
        assertNotNull(loaded)
        assertEquals(credentials, loaded)
        assertEquals("123456", loaded!!.userid)
        assertEquals("TOKEN_ROUNDTRIP_A", loaded.token)
        assertEquals("VIP_ROUNDTRIP_B", loaded.vipToken)
    }

    // ------------------------------------------------------------------
    // 2. 按 userid 隔离
    // ------------------------------------------------------------------

    @Test
    fun `按 userid 隔离_读不到未保存的账号`() = runTest {
        store.save(KugouCredentials("userA", "TOKEN_A", "VIP_A"))

        assertNull(store.load("userB"))
    }

    @Test
    fun `按 userid 隔离_两账号各自读到各自凭证`() = runTest {
        store.save(KugouCredentials("userA", "TOKEN_A", "VIP_A"))
        store.save(KugouCredentials("userB", "TOKEN_B"))

        val a = store.load("userA")
        val b = store.load("userB")
        assertNotNull(a)
        assertNotNull(b)
        assertEquals("TOKEN_A", a!!.token)
        assertEquals("VIP_A", a.vipToken)
        assertEquals("TOKEN_B", b!!.token)
        assertNull(b.vipToken)
    }

    // ------------------------------------------------------------------
    // 3. currentUserid
    // ------------------------------------------------------------------

    @Test
    fun `当前账号_未设置时返回 null`() = runTest {
        assertNull(store.currentUserid())
    }

    @Test
    fun `当前账号_设置后可读回_传 null 可清除`() = runTest {
        store.setCurrentUserid("userA")
        assertEquals("userA", store.currentUserid())

        store.setCurrentUserid(null)
        assertNull(store.currentUserid())
    }

    @Test
    fun `当前账号_与凭证存储相互独立`() = runTest {
        // 设置当前账号但未保存凭证 → 读凭证仍为 null（两张 prefs 分立）。
        store.setCurrentUserid("userA")
        assertNull(store.load("userA"))
    }

    // ------------------------------------------------------------------
    // 4. clear
    // ------------------------------------------------------------------

    @Test
    fun `清除后该账号凭证读不到_且不影响其它账号`() = runTest {
        store.save(KugouCredentials("userA", "TOKEN_A"))
        store.save(KugouCredentials("userB", "TOKEN_B"))

        store.clear("userA")

        assertNull(store.load("userA"))
        val b = store.load("userB")
        assertNotNull(b)
        assertEquals("TOKEN_B", b!!.token)
    }

    @Test
    fun `清除不存在的账号不抛异常`() = runTest {
        store.clear("neverSaved")
        assertNull(store.load("neverSaved"))
    }

    // ------------------------------------------------------------------
    // 5. 解密失败容错
    // ------------------------------------------------------------------

    @Test
    fun `密文损坏时读取返回 null 且不抛异常`() = runTest {
        val uid = "corruptUser"
        store.save(KugouCredentials(uid, "TOKEN_BEFORE_CORRUPT"))

        // 模拟「磁盘密文被篡改」：EncryptedSharedPreferences 的 editor 会加密值、
        // 且 key 也被 AES256_SIV 加密存储，直接 putString 明文键只会多出一条
        // 查不到的条目（不触发解密失败）。故绕过加密层，把载体 prefs 中**所有
        // 既有条目（key/value 均为密文）的 value 改写为不可解密内容**——等效于
        // 磁盘上的密文被篡改。
        val carrier = context.getSharedPreferences(
            EncryptedSharedPreferencesTokenStore.SECURE_PREFS_NAME,
            Context.MODE_PRIVATE,
        )
        val editor = carrier.edit()
        carrier.all.keys.forEach { key -> editor.putString(key, "GARBAGE_UNENCRYPTED") }
        editor.commit()

        // 核心断言：不抛异常（含 security-crypto 把解密失败包装出的
        // SecurityException），且按未登录处理返回 null。
        assertNull(store.load(uid))
    }

    // ------------------------------------------------------------------
    // 6. 无明文残留（本任务最核心的安全断言）
    // ------------------------------------------------------------------

    @Test
    fun `保存后 shared_prefs 下所有 xml 都不含 token 明文`() = runTest {
        val plainToken = "PLAINTEXT_TOKEN_SECRET_777"
        val plainVipToken = "PLAINTEXT_VIP_SECRET_888"
        store.save(KugouCredentials("plainUser", plainToken, plainVipToken))
        store.setCurrentUserid("plainUser")

        // save 使用 apply()（异步落盘）：显式执行主 looper 队列里的落盘任务，
        // 保证后续遍历读到的是真实落盘内容。
        shadowOf(Looper.getMainLooper()).idle()

        // 遍历应用私有目录下所有 shared_prefs/*.xml（含 security-crypto 的
        // keyset 文件、加密凭证文件、普通账号文件），断言不含任何明文。
        val sharedPrefsDir = File(context.filesDir.parentFile, "shared_prefs")
        val xmlFiles = sharedPrefsDir.listFiles { _, name -> name.endsWith(".xml") } ?: emptyArray()
        assertTrue("保存后应有 prefs 落盘文件", xmlFiles.isNotEmpty())

        for (file in xmlFiles) {
            val content = file.readText()
            assertFalse(
                "${file.name} 不得包含 token 明文",
                content.contains(plainToken),
            )
            assertFalse(
                "${file.name} 不得包含 vipToken 明文",
                content.contains(plainVipToken),
            )
        }

        // 附加：凭证仍可正常读回（说明落盘的是合法密文，而非未写入）。
        val loaded = store.load("plainUser")
        assertNotNull(loaded)
        assertEquals(plainToken, loaded!!.token)
        assertEquals(plainVipToken, loaded.vipToken)
    }

    // ------------------------------------------------------------------
    // 7. toString 脱敏
    // ------------------------------------------------------------------

    @Test
    fun `toString 不含 token 与 vipToken 明文`() {
        val credentials = KugouCredentials(
            userid = "999",
            token = "TOKEN_STRING_SHOULD_NOT_LEAK",
            vipToken = "VIP_STRING_SHOULD_NOT_LEAK",
        )

        val text = credentials.toString()
        assertFalse(text.contains("TOKEN_STRING_SHOULD_NOT_LEAK"))
        assertFalse(text.contains("VIP_STRING_SHOULD_NOT_LEAK"))
        assertTrue(text.contains("userid=999"))
    }

    // ------------------------------------------------------------------
    // 8. vipToken 两种形态 round-trip
    // ------------------------------------------------------------------

    @Test
    fun `vipToken 为 null 时可保存可读回`() = runTest {
        store.save(KugouCredentials("vipUser", "TOKEN_NOVIP"))

        val loaded = store.load("vipUser")
        assertNotNull(loaded)
        assertEquals("TOKEN_NOVIP", loaded!!.token)
        assertNull(loaded.vipToken)
    }

    @Test
    fun `vipToken 从有值覆盖为 null 后读回为 null`() = runTest {
        store.save(KugouCredentials("vipUser", "TOKEN_1", "VIP_1"))
        assertEquals("VIP_1", store.load("vipUser")!!.vipToken)

        store.save(KugouCredentials("vipUser", "TOKEN_2", null))
        val loaded = store.load("vipUser")
        assertNotNull(loaded)
        assertEquals("TOKEN_2", loaded!!.token)
        assertNull(loaded.vipToken)
    }

    // ------------------------------------------------------------------
    // 9. 同一 userid 覆盖写
    // ------------------------------------------------------------------

    @Test
    fun `同一账号重复保存时读回最新值`() = runTest {
        store.save(KugouCredentials("sameUser", "OLD_TOKEN", "OLD_VIP"))
        store.save(KugouCredentials("sameUser", "NEW_TOKEN", "NEW_VIP"))

        val loaded = store.load("sameUser")
        assertNotNull(loaded)
        assertEquals("NEW_TOKEN", loaded!!.token)
        assertEquals("NEW_VIP", loaded.vipToken)
    }
}
