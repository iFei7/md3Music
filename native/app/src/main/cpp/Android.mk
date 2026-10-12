# libkugou_jni_shim.so —— Kotlin JNI 绑定到 libkugou_server.so 纯 C FFI 的桥接库（ndk-build）。
#
# 背景：入库的 libkugou_server.so（Rust cdylib，见 kugou_api_server/rust/src/lib.rs）
# 导出的 JNI 符号是上游旧包名 Java_com_md3music_premium_KugouApiService_*，与本 App
# 的 com.gracemusic.kugou.KugouApiService 不匹配。shim.c 以正确包名重新导出
# 三个入口并转发纯 C 符号（start_server / stop_server / is_server_running）。
#
# 构建系统说明：原为 CMake 方案（CMakeLists.txt），因部分环境无法启动 SDK cmake
# （api-ms-win-crt-* API-set DLL 解析失败，STATUS_DLL_NOT_FOUND）切换为 ndk-build；
# shim 为单文件 C，无 cmake 特性依赖，ndk-build 等价且工具链更通用。
#
# 链接策略：libkugou_server.so 无 DT_SONAME，若按路径直接链接，lld 会把完整路径
# 写进 shim 的 DT_NEEDED，真机上无法解析。故以 -L 搜索路径 + -lkugou_server
# 名称链接：DT_NEEDED 记为纯库名 libkugou_server.so，运行时由 Android 链接器按
# 标准库路径（APK lib/<abi>/）自动加载。Kotlin 侧 KugouApiService.init 仍显式
# System.loadLibrary("kugou_server") 先行加载，双保险保证符号解析顺序。
LOCAL_PATH := $(call my-dir)

# 预编译 so 由 scripts/sync_jnilibs.sh 同步进 src/main/jniLibs/${TARGET_ARCH_ABI}/，
# 仅存在 arm64-v8a / armeabi-v7a（x86 系按体积决策排除，见方案文档 3.2）。
# 缺失即 fail-fast，避免产出 DT_NEEDED 悬空、运行期才崩的 so。
KUGOU_SERVER_SO := $(LOCAL_PATH)/../jniLibs/$(TARGET_ARCH_ABI)/libkugou_server.so
ifeq ($(wildcard $(KUGOU_SERVER_SO)),)
$(error libkugou_server.so 不存在：$(KUGOU_SERVER_SO)。native 工程仅支持 jniLibs 中实际存在的 ABI（arm64-v8a / armeabi-v7a），请运行 scripts/sync_jnilibs.sh 同步 so)
endif

include $(CLEAR_VARS)
LOCAL_MODULE := kugou_jni_shim
LOCAL_SRC_FILES := shim.c
LOCAL_LDFLAGS := -L$(LOCAL_PATH)/../jniLibs/$(TARGET_ARCH_ABI) -lkugou_server

include $(BUILD_SHARED_LIBRARY)
