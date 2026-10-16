package com.gracemusic.data.secure

import java.io.InputStream
import java.io.OutputStream
import java.security.Key
import java.security.KeyStoreSpi
import java.security.Provider
import java.security.SecureRandom
import java.security.Security
import java.security.cert.Certificate
import java.util.Collections
import java.util.Date
import java.util.Enumeration
import javax.crypto.KeyGenerator
import javax.crypto.KeyGeneratorSpi
import javax.crypto.SecretKey

/**
 * 测试替身：内存版「AndroidKeyStore」JCA Provider。
 *
 * ## 为什么需要它（T-P2-04 测试基础设施）
 * Robolectric 4.17（本工程测试运行时，`robolectric.properties` 固定 `sdk=32`）
 * **不支持 Android Keystore**：`KeyStore.getInstance("AndroidKeyStore")` 直接抛
 * `KeyStoreException: AndroidKeyStore not found`——android-all jar 里的
 * `android.security.keystore.AndroidKeyStoreProvider` 不会注册进 JVM 的
 * `java.security.Security` provider 列表，其 SPI 实现（Keymaster / Keystore2）
 * 又依赖 native 层，无法在 JVM 沙箱执行。
 *
 * 本 provider 以 JVM 原生 AES 密钥替代 Keystore 硬件密钥，把
 * `androidx.security:security-crypto`（MasterKey / EncryptedSharedPreferences）
 * 依赖的 Keystore 行为（按别名存取 AES256 密钥）用内存 Map 模拟，使真实的
 * `EncryptedSharedPreferences` 加解密链路可在单元测试中端到端运行。
 *
 * ## 实现约束（踩过的坑）
 * JCA 通过反射（`Class.newInstance`）实例化 SPI 类，要求 SPI 类为 **public
 * 且带 public 无参构造**——private / package-private 的内部类会抛
 * `IllegalAccessException` 导致整个 provider 不可用。故 SPI 类为顶层 public。
 *
 * ## 使用约定
 * - [ensureInstalled] 幂等注册（provider 名 "AndroidKeyStore" 全局唯一）；
 * - [reset] 清空内存密钥表（每个测试方法 `@Before` 调用，保证用例间隔离）；
 * - 仅安装于**测试进程**：注册后只有显式按名请求 "AndroidKeyStore" 的代码
 *   （即 security-crypto 链）会命中，不影响其它任何测试。
 */
object FakeAndroidKeyStoreProvider {

    /** provider 名必须与 `android.security.keystore` 完全一致（JCA 按名查找）。 */
    const val PROVIDER_NAME: String = "AndroidKeyStore"

    /** 内存密钥表：alias → SecretKey（仅测试进程内可见，不落盘）。 */
    internal val keys: MutableMap<String, SecretKey> = LinkedHashMap()

    /** 幂等注册：已注册则跳过（避免重复 addProvider）。 */
    fun ensureInstalled() {
        if (Security.getProvider(PROVIDER_NAME) == null) {
            Security.addProvider(FakeAndroidKeyStoreJcaProvider())
        }
    }

    /** 清空全部内存密钥（测试方法间隔离用）。 */
    fun reset() {
        keys.clear()
    }
}

/**
 * JCA Provider 壳：注册 KeyStore / KeyGenerator 两个服务。
 *
 * 顶层 public：构造由测试代码直接 `new`，无需 JCA 反射，但保持 public 以统一风格。
 */
class FakeAndroidKeyStoreJcaProvider : Provider(
    FakeAndroidKeyStoreProvider.PROVIDER_NAME,
    1.0,
    "Fake AndroidKeyStore for Robolectric unit tests (com.gracemusic.data.secure)",
) {
    init {
        put("KeyStore.AndroidKeyStore", FakeAndroidKeyStoreSpi::class.java.name)
        put("KeyGenerator.AES", FakeAesKeyGeneratorSpi::class.java.name)
    }
}

/**
 * 内存 KeyStore SPI：实现 security-crypto 读取路径用到的
 * `engineContainsAlias` / `engineGetKey`（MasterKeys.keyExists 与 Tink
 * AndroidKeystoreAesGcm 读取主密钥）；写路径（密钥生成）由
 * [FakeAesKeyGeneratorSpi] 直接落内存表，不经过本 SPI。
 */
class FakeAndroidKeyStoreSpi : KeyStoreSpi() {

    override fun engineGetKey(alias: String?, password: CharArray?): Key? =
        FakeAndroidKeyStoreProvider.keys[alias]

    override fun engineGetCertificateChain(alias: String?): Array<Certificate>? = null

    override fun engineGetCertificate(alias: String?): Certificate? = null

    override fun engineGetCreationDate(alias: String?): Date? =
        FakeAndroidKeyStoreProvider.keys[alias]?.let { Date(0L) }

    override fun engineSetKeyEntry(
        alias: String?,
        key: Key?,
        password: CharArray?,
        chain: Array<out Certificate>?,
    ) {
        throw UnsupportedOperationException("fake keystore 仅供读取，写入走 KeyGenerator SPI")
    }

    override fun engineSetKeyEntry(alias: String?, key: ByteArray?, chain: Array<out Certificate>?) {
        throw UnsupportedOperationException("fake keystore 仅供读取，写入走 KeyGenerator SPI")
    }

    override fun engineSetCertificateEntry(alias: String?, cert: Certificate?) {
        throw UnsupportedOperationException("fake keystore 仅供读取，写入走 KeyGenerator SPI")
    }

    override fun engineDeleteEntry(alias: String?) {
        FakeAndroidKeyStoreProvider.keys.remove(alias)
    }

    override fun engineAliases(): Enumeration<String> =
        Collections.enumeration(FakeAndroidKeyStoreProvider.keys.keys)

    override fun engineContainsAlias(alias: String?): Boolean =
        FakeAndroidKeyStoreProvider.keys.containsKey(alias)

    override fun engineSize(): Int = FakeAndroidKeyStoreProvider.keys.size

    override fun engineIsKeyEntry(alias: String?): Boolean =
        FakeAndroidKeyStoreProvider.keys.containsKey(alias)

    override fun engineIsCertificateEntry(alias: String?): Boolean = false

    override fun engineGetCertificateAlias(cert: Certificate?): String? = null

    override fun engineStore(stream: OutputStream?, password: CharArray?) {
        throw UnsupportedOperationException("fake keystore 为纯内存实现，无 store")
    }

    override fun engineLoad(stream: InputStream?, password: CharArray?) {
        // 纯内存：无需加载。
    }
}

/**
 * AES 密钥生成 SPI：接收 `android.security.keystore.KeyGenParameterSpec`
 * （security-crypto MasterKey / Tink AndroidKeystoreAesGcm 生成主密钥时传入），
 * 用 JVM 原生 `KeyGenerator("AES")` 生成同规格密钥，并按 spec 的 keystore
 * 别名存入内存表——模拟 AndroidKeyStore 的「生成即入库」行为。
 */
class FakeAesKeyGeneratorSpi : KeyGeneratorSpi() {

    private var keySizeBits: Int = 256

    private var pendingAlias: String? = null

    override fun engineInit(random: SecureRandom?) {
        // 使用 JVM 默认随机源，无需处理。
    }

    override fun engineInit(params: java.security.spec.AlgorithmParameterSpec?, random: SecureRandom?) {
        if (params is android.security.keystore.KeyGenParameterSpec) {
            pendingAlias = params.keystoreAlias
            keySizeBits = params.keySize
        }
    }

    override fun engineInit(keysize: Int, random: SecureRandom?) {
        keySizeBits = keysize
    }

    override fun engineGenerateKey(): SecretKey {
        val generator = KeyGenerator.getInstance("AES")
        generator.init(keySizeBits)
        val key = generator.generateKey()
        pendingAlias?.let { FakeAndroidKeyStoreProvider.keys[it] = key }
        return key
    }
}
