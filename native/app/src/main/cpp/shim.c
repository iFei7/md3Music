// libkugou_jni_shim.so —— Kotlin 侧 JNI 绑定与 libkugou_server.so 纯 C FFI 之间的桥接层。
//
// 为何需要 shim：入库的 libkugou_server.so 由上游 Rust 工程编译（见
// kugou_api_server/rust/src/lib.rs），其 JNI 符号是上游旧包名
// Java_com_md3music_premium_KugouApiService_*（premium），与本 App 的
// com.md3music.md3music.kugou.KugouApiService 不匹配——直接 external 声明
// 必然 UnsatisfiedLinkError。本 shim 以正确包名重新导出三个入口，内部只做
// jstring → C 字符串的类型转换后转发纯 C 符号，零业务逻辑（语义以 lib.rs 的
// C FFI 实现为准）。
//
// 符号对应关系（与 lib.rs 的 JNI 声明逐一对应，仅包名段改本 App、方法名保持）：
//   Java_..._nativeStartNode(JNIEnv*, jobject, jint port, jstring data_dir) -> jint
//     ↔ Rust Java_com_md3music_premium_KugouApiService_nativeStartNode(env, this, port: jint, data_dir: jstring) -> jint
//     ↔ C   int  start_server(int port, const char *data_dir)   // port==0 随机端口；返回实际端口，0=失败
//   Java_..._nativeIsNodeRunning(JNIEnv*, jobject) -> jboolean
//     ↔ Rust Java_com_md3music_premium_KugouApiService_nativeIsNodeRunning(env, this) -> jboolean
//     ↔ C   int  is_server_running(void)                        // 1=运行中，0=未运行
//   Java_..._nativeStopNode(JNIEnv*, jobject) -> void
//     ↔ Rust Java_com_md3music_premium_KugouApiService_nativeStopNode(env, this)
//     ↔ C   void stop_server(void)
//
// 加载链（Kotlin 侧 KugouApiService.init 保证顺序）：
//   System.loadLibrary("kugou_server")   → libkugou_server.so（C FFI 符号本体）
//   System.loadLibrary("kugou_jni_shim") → 本库（DT_NEEDED 指向 libkugou_server.so）

#include <jni.h>

// libkugou_server.so 的纯 C FFI（rust/src/lib.rs 以 #[no_mangle] extern "C" 导出，
// P0-A 已核 .dynsym 四件套齐全；此处仅声明原型，链接期由 IMPORTED 目标提供）。
extern int start_server(int port, const char *data_dir);
extern void stop_server(void);
extern int is_server_running(void);

// 显式默认可见性：确保三个 JNI 入口进入 .dynsym 动态符号表（JNI 查找只认动态符号）。
#define SHIM_EXPORT __attribute__((visibility("default")))

SHIM_EXPORT JNIEXPORT jint JNICALL
Java_com_md3music_md3music_kugou_KugouApiService_nativeStartNode(
        JNIEnv *env, jobject thiz, jint port, jstring data_dir) {
    // 入参防护：env/dataDir 为空时直接失败返回 0，绝不解引用空指针。
    // data_dir 语义见 lib.rs：用于持久化 device_info.json；空路径交由 Rust 侧判失败。
    if (env == NULL || data_dir == NULL) {
        return 0;
    }
    const char *dir = (*env)->GetStringUTFChars(env, data_dir, NULL);
    if (dir == NULL) {
        // OOM 或 JVM 挂起：GetStringUTFChars 失败返回 NULL，按启动失败处理。
        return 0;
    }
    int port_result = start_server((int) port, dir);
    (*env)->ReleaseStringUTFChars(env, data_dir, dir);
    return (jint) port_result;
}

SHIM_EXPORT JNIEXPORT jboolean JNICALL
Java_com_md3music_md3music_kugou_KugouApiService_nativeIsNodeRunning(
        JNIEnv *env, jobject thiz) {
    return is_server_running() == 1 ? JNI_TRUE : JNI_FALSE;
}

SHIM_EXPORT JNIEXPORT void JNICALL
Java_com_md3music_md3music_kugou_KugouApiService_nativeStopNode(
        JNIEnv *env, jobject thiz) {
    stop_server();
}
