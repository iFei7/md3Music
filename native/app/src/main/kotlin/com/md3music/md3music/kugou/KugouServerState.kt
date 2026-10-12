package com.md3music.md3music.kugou

/**
 * 本地酷狗 API 服务器（libkugou_server.so）的生命周期状态。
 *
 * 五态语义对标 lib/services/local_server_lifecycle.dart 的 LocalServerState：
 * - [STARTING]：启动进行中（native start 已提交，等待返回端口/就绪）；
 * - [READY]：服务器已监听，port 有效，可承接全部在线音乐请求；
 * - [FAILED]：本次启动失败（端口申请失败/超时/native 抛错），允许后续重试；
 * - [STOPPING]：显式停止进行中，此期间懒启动不自动重启（请求方按未就绪快速失败）；
 * - [STOPPED]：未运行（初始态 / 已确定性关停）。
 */
enum class KugouServerState {
    STARTING,
    READY,
    FAILED,
    STOPPING,
    STOPPED,
}

/**
 * 状态机对外发布的不可变快照（[KugouServerManager.status] 的原子单元）。
 *
 * generation 为代次标识：每次 beginStart/beginStop 自增。旧代次的启动完成时
 * 若代次已变（被停止或更新的启动接管），不得改写状态、不得完成新等待者——
 * 与 Dart LocalServerLifecycle 的 markReady/markStopped 代次校验一致。
 */
data class KugouServerStatus(
    val state: KugouServerState = KugouServerState.STOPPED,
    /** 实际监听端口；仅 [KugouServerState.READY] 时有效，其余状态为 0。 */
    val port: Int = 0,
    val generation: Int = 0,
) {
    val isReady: Boolean get() = state == KugouServerState.READY
}
