# 第二阶段 · GraceMusic Native 工程基础（phase-2-foundation）

> 对应任务：GraceMusic Native｜第二阶段：原生 Android 工程骨架与独立构建
> 记录时间：2026-10-13 ｜ 分支：`native` ｜ 本文所有事实均经源码/构建实测核实，证据以「文件:行」或命令输出给出。

## 1. 应用身份与包名决策（已定稿，不再讨论）

| 项 | 值 | 证据 |
|---|---|---|
| 应用显示名（安装后） | **Grace** | `native/app/src/main/res/values/strings.xml:7` `app_name` |
| 品牌全称 | **GraceMusic**（中文 `优雅音乐`） | 同文件 `:8-9`（`brand_name` / `brand_name_zh`） |
| applicationId | **`com.gracemusic.app`** | `native/app/build.gradle.kts:81` |
| namespace | **`com.gracemusic`** | 同文件 `:56` |
| versionCode / versionName | `1` / `1.0.0-grace` | 同文件 `:84-85` |
| minSdk / targetSdk / compileSdk | **24 / 35 / 36** | 同文件 `:82-83`（minSdk 亦见 `:57` 注释区） |
| ndkVersion | `28.2.13676358` | 同文件 `:58` |

设计说明：
- applicationId 与 namespace **有意分离**：applicationId 是应用商店/系统身份（`com.gracemusic.app`，与旧版 `com.md3music.md3music.lite` 完全不同，可并行安装）；namespace 是 Kotlin 代码命名空间（`com.gracemusic`），JNI 符号按 namespace 机械派生（见 §7）。
- 包名决策过程见第一阶段 `plans/grace-identity-migration-2026-10-13.md`；由用户 2026-10-13 确认「安装显示 Grace，全称 GraceMusic」。**发布后 applicationId 不可更改**，后续升级只改 versionCode。
- Manifest：`android:name=".Md3MusicApp"`（`AndroidManifest.xml:18`）、`allowBackup="false"`（`:19`）、MainActivity `singleTask`（`:27-31`）。

## 2. 分支与基准 SHA

| 项 | 值 |
|---|---|
| 当前分支 | `native`（本地唯一工作分支；另有 `rust-local-force` 为 lite 线跟踪分支） |
| native HEAD | `1d811962153cebc7098a0894a84ca262d69d35d6`（与 `origin/native` **完全同步**，已推送） |
| origin | `git@github.com:iFei7/md3Music.git`（native 分支即推送至此仓的 `native` 分支） |
| upstream | `git@github.com:zzyoxml/md3Music.git` |
| rust-local-force（本地 lite 线）HEAD | `85b5dbe`（与 `origin/rust-local-force` 同步） |
| native 与 lite 线 merge-base | `ebf48e299631f7a71b529a37e4bfc76da300e41c`；native 自有 **122** 个提交 |
| 工作区状态 | 干净（本文档提交前仅有本阶段新增的 lint 基线等变更，见 §8） |

**审计基线漂移（已记录）**：第一阶段审计记录的 lite 基线 `a5ed9cd` **不在本地克隆历史中**（lite 线此后继续前进，且用户侧 lite 去密钥工作在另一克隆进行）。因此本阶段以 **native HEAD `1d81196` 为实际基准**，不复用旧 SHA。lite 线功能代码本阶段零改动。

## 3. 工程目录结构

Gradle 根在 `native/`（**不是**仓库根）：模块仅 `:app` 与 `:media3fork`（`native/settings.gradle.kts:36,39`，含 JitPack 仓 `:32`）。

```
md3Music-native/                     # 仓库根（iFei7/md3Music 的 native 分支内容）
├─ android/                          # 旧版 Flutter 宿主工程（保留不动）
├─ lib/  test/  web/  img/ …         # 旧版 Flutter 源码与资产（保留不动）
├─ kugou_api_server/rust/            # Rust 服务源码（保留，见 §7）
├─ third_party/just_audio/           # vendored media3 fork 源码（srcDirs 指向此处）
└─ native/                           # ★ 原生 Android 工程（Gradle 根）
   ├─ settings.gradle.kts            # :app + :media3fork
   ├─ gradle/libs.versions.toml      # 版本目录（唯一版本事实源）
   ├─ keystore.properties(.example)  # 签名配置（本体 gitignored / 示例可提交）
   ├─ scripts/sync_jnilibs.sh        # jniLibs 同步 + 体积门禁（CI 调用）
   ├─ media3fork/                    # vendored media3 1.4.1 构建模块
   │   └─ build.gradle.kts:35,55-61  # srcDirs 零拷贝指向 ../third_party/just_audio
   └─ app/
      ├─ build.gradle.kts            # 身份/签名/lint 基线/abiFilters 等
      ├─ lint-baseline.xml           # 第二阶段新增（收纳既有 lint 问题）
      ├─ src/main/kotlin/com/gracemusic/      # 原生源码根（66 个 .kt）
      │   ├─ Md3MusicApp.kt           # @HiltAndroidApp
      │   ├─ MainActivity.kt          # @AndroidEntryPoint 单 Activity + enableEdgeToEdge
      │   ├─ ui/Md3MusicApp.kt        # Routes×9 + NavHost + 占位屏装配
      │   ├─ core/{theme,responsive,ui}/      # M3 主题（动态色/OLED）/窗口分级/背景占位
      │   ├─ di/                      # 6 个 Hilt SingletonComponent 模块
      │   ├─ data/model/              # Song 等领域模型
      │   ├─ feature/{home,library,onboarding,personalfm,player,playlist,search,settings,user}/  # 9 路由占位屏
      │   ├─ player/{engine,gate,session,state,queue,model}/   # 播放域（P1 已交付部分）
      │   └─ kugou/                   # KugouApiService(JNI)/Gateway/Manager/State
      ├─ src/main/java/               # 仅 3 个 Viper DSP Java 文件（逐字节移植）
      ├─ src/main/cpp/                # Android.mk + shim.c（JNI shim，ndk-build）
      ├─ src/main/jniLibs/            # 预构建 so（已跟踪）：arm64-v8a/armeabi-v7a
      ├─ src/main/res/                # 品牌图标/主题/widget 布局等
      └─ src/test/                    # JVM 单测（Robolectric sdk=32）
```

## 4. 技术栈与版本（实测自 `libs.versions.toml`）

| 层 | 选型 | 版本 | 备注 |
|---|---|---|---|
| 构建 | Gradle / AGP | 9.1.0（腾讯镜像）/ 9.0.1 | 与 Flutter 工程锁定一致 |
| 语言 | Kotlin / KSP | 2.3.20 / 2.3.12 | KSP 独立序号，中央库最新匹配版 |
| UI | Compose BOM | 2026.06.01 | → compose 1.11.4 / material3 1.4.0；1.12.x 要 API37+AGP9.1 不可用 |
| 架构 | MVVM+UDF / Coroutines | — / 1.11.0 | StateFlow 单向数据流 |
| DI | Hilt / hilt-navigation-compose | 2.60.1 / 1.3.0 | KSP 处理 |
| 导航 | navigation-compose | 2.9.7 | 2.10.x 要 API37 不可用 |
| 数据库 | Room | 2.8.5 | 已声明依赖，**尚未建库建表**（P2 数据层任务） |
| 网络 | Retrofit / OkHttp | 2.12.0 / 4.12.0 | 已声明，未建业务 API |
| 图片 | Coil3 | 3.5.0 | 3.6.x 要 API37 不可用 |
| 存储 | DataStore / security-crypto / Work | 1.2.1 / 1.1.0 / 2.12.0 | 主题设置等后续接入 |
| 播放 | Media3 | **1.4.1（vendored fork，禁改 Maven 版）** | 对齐 just_audio fork 内嵌源码 |
| 测试 | JUnit / Robolectric | 4.13.2 / 4.17 | Robolectric 钉 sdk=32（见 §6） |

版本选取原则（源自 catalog 头注释）：AGP/Kotlin 与 Flutter 工程锁定一致不得更改；androidx 各产线取「minCompileSdk≤36 且 minAgp≤9.0.1」的最新稳定版；media3 锁 1.4.1 对齐 fork。

## 5. 模块职责与架构边界

- **`:app`**：应用全部原生代码、资源、签名、lint 基线；显式排除 Maven media3-exoplayer/session（`app/build.gradle.kts:179-182`），仅 common/decoder 走 Maven（`:223-228`）。
- **`:media3fork`**：vendored media3 1.4.1 构建模块，namespace `com.ryanheise.just_audio`（`media3fork/build.gradle.kts:38`，原因见决策 D2-08），srcDirs 零拷贝指向 `third_party/just_audio`（`:35,55-61`），minSdk 同为 24（`:42`）。有门禁测试 `AudioEngineFactoryTest.forkCustomizationsRemainAvailable` 防止误换 Maven 版。
- **播放架构边界（为后续 Media3 集成预留，本阶段不实现播放器）**：UI 不持有播放器实例；未来经 `MediaSessionService`（`Md3MediaSessionService` 已在 Manifest 注册，`AndroidManifest.xml:44`）+ `MediaController`/封装接口访问；播放状态统一 StateFlow 暴露（`player/state/` 已交付意图词汇表与状态模型）；不提前创建无用途前台服务、不加保活黑科技。
- **Rust 边界**：`kugou/` 包经 JNI 调 `libkugou_jni_shim.so` → `libkugou_server.so`；shim 是纯 C 转发层（见 §7）。JNI/FFI、DSP、音频处理链路**尚未正式接通业务**，后续验证通过后再接入。

## 6. Debug / Release 签名配置机制

- **Debug**：AGP 默认调试签名（自动生成的 debug keystore），独立于任何发布密钥。
- **Release**：双来源取值——`native/keystore.properties`（本地，**gitignored**）优先，环境变量 `ANDROID_KEYSTORE_PATH/PASSWORD/ALIAS/KEY_PASSWORD` 兜底（`app/build.gradle.kts:24-39` `signingValue`）。四项齐全才装配 signingConfig（`:123-134`）。
- **Fail-fast 门禁**：`assembleRelease*`/`bundleRelease*`/`packageRelease*` 任一入图而签名未配 → `throw GradleException`（`:161-173`）——**不存在无签名包，也不存在偷偷回退 debug 签名的 release**。
- **CI**：`.github/workflows/native.yml` 用 4 个 GitHub Secrets（`ANDROID_KEYSTORE_BASE64/PASSWORD/ALIAS/KEY_PASSWORD`，`:168-171` 检测、`:210-233` 注入）；缺 Secret 时跳过 release、降级 `assembleDebug` 并在资产名标注，release job 整体跳过（`:304-306,:496`）——CI 绿 ≠ 发布签名包，需看 job 明细。
- **示例配置**：`native/keystore.properties.example`（本阶段新增，可提交；仅占位符，无真实凭证）。
- **gitignore 三层覆盖**（实测 `git ls-files` 无任何 keystore/jks 被跟踪）：`native/.gitignore:12-14`、仓库根 `.gitignore:5-7`、`android/.gitignore:10-12`。2026-10-13 已移除根 gitignore 里导致 lite keystore 泄露的 `!keystore/*.keystore` 例外（提交 `a68340c`）。
- **Release 签名验证状态**：✅ 已验证。`gracemusic` key（RSA 4096，`CN=GraceMusic`，SHA-256 `b8c0edd2…40054`）本地 `assembleRelease` 与 CI 发布产物（`v1.0.0-grace-native-1d81196`）均经 `apksigner verify --print-certs` 实测通过。注意：该 key 目前同时签 GraceMusic 与 lite（用户 2026-10-13 决定共用以快速止血），泄露会同时波及两应用，拆分需再次付出卸载重装代价。

## 7. 与旧版 Flutter / Rust 工程的关系

- **Flutter 工程零依赖**：三个 gradle 文件无 `io.flutter` 依赖；`io.flutter` 仅出现在 DSP Java 文件注释中。旧版 `lib/`、`android/`（Flutter 宿主）、`web/` 全部保留未动。
- **Rust 服务保留并已接线到原生侧**：
  - 源码 `kugou_api_server/rust/`（未重写、未删除）；
  - C shim `native/app/src/main/cpp/shim.c` + `Android.mk`（ndk-build；`-lkugou_server` 名称链接防 DT_NEEDED 写绝对路径，缺 so 即 `$(error)` fail-fast）；
  - JNI 符号已按新 namespace 机械派生：`Java_com_gracemusic_kugou_KugouApiService_native{StartNode,IsNodeRunning,StopNode}`（shim.c:38-62 符号表），**发布产物内实测三符号齐全、旧 `Java_com_md3music*` 零残留**；
  - 预构建 so 已跟踪：`arm64-v8a/libkugou_server.so` 4,872,184 B、`arm64-v8a/libflacJNI.so` 531,320 B、`armeabi-v7a/libkugou_server.so` 3,411,044 B；x86 已排除（abiFilters 仅 arm64-v8a/armeabi-v7a，`app/build.gradle.kts:91`）；
  - `scripts/sync_jnilibs.sh` 由 CI 调用并做体积硬门禁（`native.yml:101-146`）。
- **环境坑记录**：沙箱内 SDK cmake 3.22.1 不可用（api-ms-win-crt-* 解析失败）→ 原生构建走 ndk-build；AGP 9.0.1 无 `testReleaseUnitTest` 任务。

## 8. 本阶段已完成 / 未完成

**已完成（均有实测证据，见 phase-2-validation.md）**
1. 原生工程可独立构建（`:app` + `:media3fork`，不依赖 Flutter 运行时）。
2. 应用身份落地：applicationId / namespace / 显示名 / 版本号 / 品牌图标与字符串。
3. 基础 Compose 应用可运行：Application（Hilt）、MainActivity（单 Activity + edge-to-edge）、M3 主题（深色跟随系统 + Android 12 动态色 + 低版本回退 + OLED 纯黑开关）、9 路由 NavHost 占位、WindowSizeClass 响应式、统一 `RoutePlaceholder`。
4. Debug/Release 双变体 + Release fail-fast 签名门禁 + 示例配置 + CI Secrets 机制。
5. 质量保障：343 单测全绿 + lint 基线化 + 构建验证四命令全过。
6. 播放域 P1 已交付部分在位（engine/gate/session/state/queue/model + kugou JNI 服务），为后续 Media3 集成预留边界。

**未完成（本阶段明确不做，非遗漏）**
1. 真实业务页面（9 路由均为占位屏，无假业务数据）。
2. 迷你播放器布局接口已预留（`ui/Md3MusicApp.kt` 路由装配与 `RoutePlaceholder` 结构），未接线。
3. 主题开关接 DataStore：`MainActivity.kt:24-27` 有 TODO，当前 `dynamicColor`/`oledBlack` 默认 false。
4. Room 建库、Retrofit 业务 API、Repository（路线图 P2 数据层）。
5. 浮动 Dock、全屏播放器、播放队列、歌词、搜索播放、音频设备控制（P3–P5）。
6. 播放缓存仅完成范围界定（见决策 D2-02），未实现。
7. 真机安装启动验证（本环境无模拟器）。

## 9. 第一阶段文档与源码的漂移（验收时发现，以此为准）

第一阶段 6+1 份文档写在 G1 身份迁移（`83d058a`）之前，以下条目已过期，**一律以源码为准**：

| 文档:行 | 过期表述 | 源码事实 |
|---|---|---|
| `native-architecture.md:193`（及 `:786`） | applicationId = `com.md3music.md3music.native` | `com.gracemusic.app`（build.gradle.kts:81） |
| `native-architecture.md:126` | 源码根 `com/md3music/md3music/` | `com/gracemusic/` |
| `native-architecture.md:723` | CI 装配内置 keystore `../android/keystore/lite-release.keystore` 且断言旧 applicationId | CI 用 4 个 Secrets 并断言 `com.gracemusic.app`；lite keystore 已被 `a68340c` 删除 |
| `native-architecture.md:732` | 「signingConfigs 尚未配…产物可能 unsigned」 | 已配 + fail-fast 门禁（:161-173） |
| `architecture-audit.md:130` | applicationId = `com.md3music.md3music.native` | 同上 |
| `data-migration-design.md:41` | GraceMusic 身份「尚未落地 native:」 | `83d058a`（2026-10-13）已落地 |
| `implementation-roadmap.md:24` | 「正处 P1-5b 入口，12 个提交」 | HEAD 后又新增 G1/G2/CI 降级/安全整改/资产命名共 5 提交；本阶段基础已验证（见同文件 §1.1 更新） |

一致性复核通过项：minSdk 24/targetSdk 35/compileSdk 36；media3fork srcDirs 行号引用；9 处 fork 改动；两个 Android 7–9 问题描述；SuperLyric native 未移植；Robolectric sdk=32。
