package com.gracemusic.kugou

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 本地 Rust API 服务器（libkugou_server.so）的最小操作面。
 *
 * [KugouServerManager] 只依赖本接口：生命周期状态机因此与 native 完全解耦，
 * 单测以 [FakeGateway] 隔离即可覆盖全部分支，无需真机/模拟器。
 */
interface KugouServerGateway {

    /**
     * 启动服务器，返回实际监听端口（<= 0 表示失败）。
     *
     * @param dataDir device_info.json 持久化目录（不能为空）。
     */
    suspend fun start(dataDir: String): Int

    /** 停止服务器（Rust 侧幂等，未运行时调用为无操作）。 */
    suspend fun stop()

    /** 服务器是否正在运行（Rust 侧原子标志查询）。 */
    suspend fun isRunning(): Boolean
}

/**
 * 基于 JNI shim 的 [KugouServerGateway] 实现。
 *
 * - 所有 native 调用切 [Dispatchers.IO]：Rust 的 start/stop 会 join 监听线程，
 *   同步调用可能阻塞数十毫秒，不得占用调用方线程；
 * - 懒加载 [KugouApiService]：首次调用时才 dlopen；加载失败时 lazy 不缓存异常，
 *   后续调用会重新尝试；
 * - 链接类 Error（so 缺失、JNI 符号不匹配等 UnsatisfiedLinkError /
 *   ExceptionInInitializerError）转换为 [IllegalStateException]，交由
 *   KugouServerManager 置 failed 态，避免 Error 直接逃逸到 UI 层。
 */
class NativeKugouServerGateway : KugouServerGateway {

    private val service: KugouApiService by lazy {
        try {
            KugouApiService()
        } catch (e: LinkageError) {
            throw IllegalStateException(
                "kugou JNI 库加载失败（libkugou_server / libkugou_jni_shim）",
                e,
            )
        }
    }

    override suspend fun start(dataDir: String): Int = withContext(Dispatchers.IO) {
        service.nativeStartNode(RANDOM_PORT, dataDir)
    }

    override suspend fun stop() {
        withContext(Dispatchers.IO) { service.nativeStopNode() }
    }

    override suspend fun isRunning(): Boolean = withContext(Dispatchers.IO) {
        service.nativeIsNodeRunning()
    }

    private companion object {
        /** port = 0：由 Rust 侧随机选端口。 */
        const val RANDOM_PORT = 0
    }
}
