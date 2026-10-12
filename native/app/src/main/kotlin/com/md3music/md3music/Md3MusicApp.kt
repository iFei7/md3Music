package com.md3music.md3music

import android.app.Application
import dagger.hilt.android.HiltAndroidApp

/**
 * md3Music 原生版 Application。
 *
 * Hilt 依赖注入容器入口；真实主题与导航为后续任务，本类当前仅承载 DI。
 */
@HiltAndroidApp
class Md3MusicApp : Application()
