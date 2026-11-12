package com.md3music.md3music

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Bundle

/**
 * 悬浮识曲投射授权 trampoline：透明、不落 recents、立即 finish。
 *
 * 背景：此前授权走 MainActivity.onActivityResult（由 Dart 发起），
 * 会把应用整体拉回前台，且授权后停留前台不返回。现由
 * FloatingRecognitionService（FGS）直接启动本 activity 承接
 * createScreenCaptureIntent 弹窗，用户始终停留在外部页面/桌面。
 *
 * BAL（后台 activity 启动）说明：从 FGS 启动 activity 属后台启动限制场景，
 * 本应用持有 SYSTEM_ALERT_WINDOW 且悬浮窗当前可见，属官方口径中的典型豁免
 * （「应用有可见叠加窗口」即可后台启动 activity）。但各 ROM 实现口径不一，
 * MIUI/HyperOS/HarmonyOS 等需真机验证。
 *
 * REQUEST_CODE = 10001 与原 MainActivity.RECOGNITION_PROJECTION_REQUEST
 * （现已删除）同值，保持请求码语义延续。
 *
 * taskAffinity=""（manifest 声明）：不并入主 task，弹窗关闭 finish 后本
 * task 为空，系统自动回到用户原 task。
 */
class RecognitionConsentActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 透明 trampoline：仅承接系统投射授权弹窗，弹窗关闭立即 finish。
        // 旋转/重建（configChanges 已兜住常见项，此处再兜底）不重复拉弹窗。
        if (savedInstanceState == null) {
            val pm = getSystemService(MediaProjectionManager::class.java)
            @Suppress("DEPRECATION")
            startActivityForResult(pm.createScreenCaptureIntent(), REQUEST_CODE)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_CODE) {
            // 静态注入服务（onProjectionResult → instance.handleProjectionResult），
            // 拒绝授权（RESULT_CANCELED）同样走该通道，由服务侧 toast + 回 IDLE。
            FloatingRecognitionService.onProjectionResult(resultCode, data)
        }
        // 无条件 finish（拒绝授权也要 finish），本 task 空后系统自动回用户原 task。
        finish()
    }

    companion object {
        const val REQUEST_CODE = 10001
    }
}
