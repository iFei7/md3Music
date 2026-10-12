package com.md3music.md3music.kugou

/**
 * libkugou_jni_shim.so 的 JNI 绑定边界——本包唯一声明 external 方法的类，
 * 零业务逻辑，只负责加载原生库与暴露 native 入口。
 *
 * 符号对应 native/app/src/main/cpp/shim.c 导出的三个函数
 * （Java_com_md3music_md3music_kugou_KugouApiService_*，按本类全限定名改编），
 * shim 内部转发 libkugou_server.so 的纯 C FFI：
 * - nativeStartNode ↔ start_server(port, data_dir)
 * - nativeIsNodeRunning ↔ is_server_running()
 * - nativeStopNode ↔ stop_server()
 *
 * 为何需要 shim：入库的 libkugou_server.so 由上游 Rust 工程编译，其 JNI 符号是
 * 旧包名 Java_com_md3music_premium_KugouApiService_*，与本类包名不匹配，
 * 直接绑定必然 UnsatisfiedLinkError（详见 shim.c 头注释）。
 *
 * 加载链（init 内显式按序两次加载，双保险）：
 * 1. libkugou_server.so——C FFI 符号本体，先加载；
 * 2. libkugou_jni_shim.so——DT_NEEDED 指向 libkugou_server.so，后加载。
 * 任一失败抛 ExceptionInInitializerError，由 NativeKugouServerGateway 转换为
 * 普通异常、KugouServerManager 置 failed 态（Error 不会直接掀翻 UI 层）。
 */
class KugouApiService {

    init {
        System.loadLibrary("kugou_server")
        System.loadLibrary("kugou_jni_shim")
    }

    /**
     * 启动本地 API 服务器。
     *
     * @param port 传 0 由 Rust 侧随机选端口（被占用则 1s 后换下一个，最多 10 次）。
     * @param dataDir 用于持久化 device_info.json（重启后 dfid/mid 不变）。
     * @return 实际监听端口；0 表示失败（端口耗尽或 dataDir 无效）。
     */
    external fun nativeStartNode(port: Int, dataDir: String): Int

    /** 服务器是否正在运行（Rust 侧原子标志，非网络探测）。 */
    external fun nativeIsNodeRunning(): Boolean

    /** 停止服务器（Rust 侧幂等；内部会 join 监听线程，可能阻塞，调用方须放 IO 线程）。 */
    external fun nativeStopNode()
}
