# 第二阶段 · 构建与验证记录（phase-2-validation）

> 记录时间：2026-10-13 ｜ 分支 `native` HEAD `1d81196`（本阶段验证时的代码状态；文档与 lint 基线提交见文末）
> 原则：**只记录真实执行结果**。跳过的项明确标注「未验证/环境阻塞」，不冒充通过。

## 1. 执行环境

| 项 | 值 |
|---|---|
| JDK | `C:/Users/hwx1254427/dev-tools/jdk-17.0.20.1+1`（JDK 17） |
| Android SDK | `~/dev-tools/android-sdk`（platforms/android-36、build-tools/36.1.0、NDK 28.2.13676358） |
| Gradle | 9.1.0（wrapper，腾讯镜像） |
| 模拟器/真机 | **无**（本环境不提供）→ 安装启动项未验证 |

## 2. 实际执行的命令与结果

工作目录：`C:/Users/hwx1254427/WorkBuddy/md3Music-native/native`；每条命令均以 `JAVA_HOME` 指向上述 JDK17。

| # | 命令 | 退出码 | 结果 |
|---|---|---|---|
| 1 | `./gradlew projects` | **0** | 工程结构正确识别：根 `native`，子模块 **`:app`** 与 **`:media3fork`** |
| 2 | `./gradlew :app:assembleDebug` | **0** | Debug APK 生成（见 §3） |
| 3 | `./gradlew :app:testDebugUnitTest --rerun-tasks` | **0** | **343 个测试 / 0 失败 / 0 跳过**（全量重跑，非增量） |
| 4 | `./gradlew :app:lintDebug` | **0** | 首轮 4 errors → 处置后复跑通过，新增 issue 为 0（见 §4） |

## 3. Debug APK 产物

- 路径：`native/app/build/outputs/apk/debug/app-debug.apk`
- 大小：**25,871,516 字节**（约 24.7 MB）
- SHA-256：`cd434336d844dd2fd1f19c24731d45d30064df32fa9e3d9fd78597af6e1de96f`
- 包内身份（aapt2 dump badging 实测）：`package=com.gracemusic.app`、`versionName=1.0.0-grace`、`application-label=Grace`、targetSdkVersion 35
- 包内原生库：`lib/arm64-v8a/`、`lib/armeabi-v7a/` 各含 `libkugou_jni_shim.so`、`libkugou_server.so`、`libflacJNI.so` 等；JNI 符号实测为 `Java_com_gracemusic_kugou_KugouApiService_native*`（旧包名符号 0 残留）

> 对照：CI 发布链路（run `38378296920`）产出的 release APK `GraceMusic-native-v1.0.0-grace-1d81196.apk`（20,771,578 B）已另行验证——`apksigner verify` 通过（v2 scheme），签名者 `CN=GraceMusic`，证书 SHA-256 `b8c0edd22df58a4adb4c0c438802a7f4049c81fd749ea833d59cafe7cfe40054`。

## 4. Lint 结果明细

- **首轮** `lintDebug`：4 errors = 3 × `NewApi` + 1 × `PropertyEscape`。
- **处置**：
  1. `PropertyEscape`：根因是本地 `native/local.properties` 路径转义（该文件 gitignored，属本地环境项），本地修正；
  2. 3 × `NewApi`：位于 `PlaybackNotificationChannels.kt` 的 O+ API，仅由已做 `Build.VERSION.SDK_INT < O` 守卫的 `ensureCreated` 调用（运行期安全）；本阶段不改业务源码补 `@RequiresApi`，按 AGP 建议以 **lint 基线**收纳；
  3. 新增 `native/app/lint-baseline.xml`（92 条既有 issue：error 级即上述 3 处 NewApi；其余为 `InlinedApi`×1、`ExportedService`×1、`UnusedResources`×52、`UnusedAttribute`×10、`GradleDependency`×7 等 warning 级），并在 `app/build.gradle.kts` 接线 `lint { baseline = file("lint-baseline.xml") }`。
- **复跑**：退出码 0，**新增 error 0 / 新增 warning 0**（`warningsAsErrors` 未开启，warning 不阻断）。
- 报告位置：`native/app/build/reports/lint-results-debug.html`。

## 5. 安装与启动验证

- **未执行（环境阻塞）**：本环境无 Android 模拟器、无连接真机。
- 替代证据：APK 成功生成 + 包名/标签/SDK 级/原生库经 `aapt2`/`apksigner` 实测正确；Application/MainActivity 启动路径的 API 兼容性经静态核查（§6）。
- **待办**：在用户环境执行安装启动冒烟（安装 → 启动 → 9 路由占位屏可导航 → 深色/浅色切换正常）。

## 6. minSdk=24 兼容性静态核查（真机行为未验证）

- 启动路径（`Md3MusicApp` → `MainActivity` → `Md3MusicTheme` → `ui/Md3MusicApp` → `AppBackground` → `RoutePlaceholder`）共 4 处 `SDK_INT` 判断，**全部有守卫**：
  - `core/theme/Md3MusicTheme.kt:71`（API 31 动态色，`supportsDynamicColor()`）
  - `player/session/MediaButtonReceiver.kt:60`（TIRAMISU）
  - `player/session/PlaybackKeepAliveService.kt:109`（O）
  - `player/session/PlaybackNotificationChannels.kt:59,79`（O，入口 `if (SDK_INT < O) return`）
- `enableEdgeToEdge()` 为 AndroidX 兼容 API，minSdk 24 可用。
- 测试侧：Robolectric 钉 `sdk=32`（`app/src/test/resources/robolectric.properties`，防按 targetSdk 35 静默回退 API 23）；`DynamicColorSupportTest` 以 `@Config(sdk=[31])`/`@Config(sdk=[30])` 成对覆盖动态色开/关。
- **未验证**：Android 7–9 真机行为（无设备）。

## 7. 已知问题与复现方式（本阶段未修，已登记为后续必修）

### 7.1 MediaStoreScanner RELATIVE_PATH（Android 7–9 本地媒体扫描为空）

- 位置：`android/app/src/main/kotlin/com/md3music/md3music/MediaStoreScanner.kt:98`（lite 侧，native 未移植该文件）
- 问题：`getColumnIndexOrThrow(MediaStore.Audio.Media.RELATIVE_PATH)`（API 29+ 列）无 `getColumnIndex` 回退；同函数 `:100-101` 对 bitrate 列却有安全写法，可见疏漏。
- 复现：Android 7–9 设备打开「本地音乐」扫描 → 查询抛异常 → catch 后回退 `queryAll` 再次用同一 projection → 再抛 → 静默返回空列表（`:71-77`、`:156`）。
- 状态：代码原样在位，git 历史仅 `9cee83e` 一次提交、此后无修复。

### 7.2 SuperLyricHelper.registerPublisher() 捕不住 Error

- 位置：`android/app/src/main/kotlin/com/md3music/md3music/AudioPlaybackService.kt:621-623`（`onCreate` 内）
- 问题：`try { SuperLyricHelper.registerPublisher() } catch (_: Exception) {}` —— `catch(Exception)` 无法捕获 `Error` 子类（如 `NoClassDefFoundError`），依赖缺失时进程崩溃而非降级。
- 状态：原样在位（近 5 次提交未触及）；native 侧未移植 SuperLyric（`grep -rn SuperLyric native/` 零命中）。

### 7.3 主题开关未接 DataStore

- `MainActivity.kt:24-27` TODO：`dynamicColor`/`oledBlack` 当前默认 false，主题设置尚未持久化（规范键迁移策略见 decisions D2-07）。

## 8. 环境限制清单

1. 无模拟器/真机 → 安装启动未验证（§5）。
2. 沙箱内 SDK cmake 3.22.1 不可用（`api-ms-win-crt-*` 解析失败）→ 原生构建走 ndk-build（已适配，非阻塞）。
3. AGP 9.0.1 无 `testReleaseUnitTest` 任务 → 单测统一 `testDebugUnitTest`。
4. Robolectric 需 `sdk=32`（targetSdk 35 的 android-all 本地无缓存，会静默回退 API 23 导致假失败）。
5. 沙箱无 GitHub Token/gh CLI → 私有仓 API 操作不可用（公开只读 API 可用）；release 签名的 CI  Secrets 由用户侧配置。

## 9. 本阶段产生的工程变更（随本文档一同提交）

| 文件 | 变更 | 用途 |
|---|---|---|
| `native/app/lint-baseline.xml` | 新增 | 收纳 92 条既有 lint issue，仅对新增 error 失败 |
| `native/app/build.gradle.kts` | +8 行 | `lint { baseline = … }` 接线 + 基线构成注释 |
| `native/keystore.properties.example` | 新增 | 签名配置示例模板（占位符，无真实凭证） |
| `docs/native/phase-2-*.md` | 新增 3 份 | 本阶段文档交付 |
