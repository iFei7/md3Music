# 第三阶段 · 播放引擎验证报告

> 本报告记录第三阶段（T-P1-01/T-P1-02）播放引擎的真实接线路径、测试结果与边界验证结论。
> **总原则**：所有"已验证"均指出具体命令与 XML 级结果；真机行为、在线音源、Android 7–9 兼容**未验证**，原因逐项登记。

---

## 1. 引擎实现类型

| 项 | 事实 |
|---|---|
| 引擎 | **Media3 ExoPlayer 1.4.1（vendored fork）**——`:media3fork` 模块 srcDirs 零拷贝指向 `third_party/just_audio/android`，namespace `com.ryanheise.just_audio`；app 排除 Maven exoplayer/session（`app/build.gradle.kts:184-232`） |
| 实例 | `AudioEngine`（@Singleton @MainThread，`di/PlayerModule.kt:53-57`）封装进程唯一 ExoPlayer；本阶段未新建播放器实例 |
| 适配层 | `ExoPlayerPlaybackEngineAdapter`（349 行）：单曲时间线 + 真实控制 API + 监听桥接 + 200ms 位置采样 + 释放安全 |
| 时间线模型 | **单曲时间线**（与 lite `setUrl` 一致）：每次 prepare 用单个 MediaItem（mediaId=`Song.id`）重建；引擎循环恒关，队列推进由 App 层负责 |
| 线程模型 | 一切引擎调用主线程（media3 `verifyApplicationThread()` 实证：vendored `ExoPlayerImpl.java:1521-1523`）；适配器入口 `checkMainThread()`，非主线程抛 `IllegalStateException`（11 个公开方法全部测试验证） |

## 2. 已接通的实际调用路径（无空操作桩）

### 2.1 下行（控制）

```
UI/调用方 ──dispatch(intent)──┐
媒体键 MediaButtonReceiver ──→ PlaybackKeepAliveService ──→ registry.dispatch(PlayerCommand) ──┐
通知 NEXT/PREVIOUS（Md3MediaSessionCallback 拦截）──────────────────────────────────────────────┤
                                                                                              ▼
                                                    PlaybackStore.dispatch(command) → 翻译表 → dispatch(intent)
                                                                                              │ issue() 记代次
                                                                                              ▼
                                                    PlaybackReducer.reduce（纯函数）→ PlaybackTransition(state, effects)
                                                                                              │ 先发布 _state，再按序执行
                                                                                              ▼
                                                    效果执行器：Prepare/Play/Pause/Stop/SeekTo/SeekBy/SetVolume/SetSpeed
                                                                                              ▼
                                                    ExoPlayerPlaybackEngineAdapter → ExoPlayer 真实 API
```

### 2.2 上行（事实回流）

```
ExoPlayer（Player.Listener）→ 适配器按值去重 → EngineListener
  onPlaybackStateChanged / onIsPlayingChanged / onDurationChanged / onCurrentSongChanged(mediaId) / onPlaybackCompleted / onError
      → PlaybackStore 内部 listener
      → （onCurrentSongChanged：mediaId → 当前队列下标解析，找不到丢弃+日志）
      → （onError：ErrorEventGate 过滤）
      → dispatch(event) → PlaybackReducer.reduce → _state 发布
  ExoPlayer positionFlow（200ms 采样）→ Store onPositionSample：RewindGate 抑制 → position 流 → ProgressGate 首真 → PlaybackProgressConfirmed
```

### 2.3 关键接线的测试证据（假引擎 + 真 registry + 真闸门，33 例）

- 10 条 `PlayerCommand` → 意图翻译表逐条（含 `TogglePlayPause` 两态、空队列播放族 no-op）；
- attach 前后：未 attach 时 `registry.dispatch` → BUFFERED；attach → 同步重放 → 引擎收到调用（`PlaybackSessionRegistryTest` 之外新增 Store 级闭环）；
- 意图→引擎调用序列：本地曲目 PlaySingleSong/Resume/Pause/Stop/SeekTo/SeekBy/SetVolume/SetSpeed/Next/Previous/RetryCurrent；
- 通知栏 PLAY_PAUSE 模拟（不经意图）：`onIsPlayingChanged(true/false)` → isPlaying 状态 + 保活对账；
- 位置管线：装载窗内抑制采样不闪回；首真推进清 `awaitingPlaybackProgress`；
- 过期事件：快速 Next Next 后迟到旧曲切换被丢弃；释放后回调不改变状态；
- 错误入口 4 例（装载后落状态/停机后过滤/装载前过滤/RetryCurrent 重备）；
- Completed 队列语义 2 例（ALL 推进/OFF 停机、ONE 重播）；
- CDN 看门狗 6 例（触发/最小间隔/未播放/本地曲/位置<45s/装载保护窗）。

### 2.4 适配器层测试证据（Robolectric 真 ExoPlayer，26 例）

- 时间线投射 8：mediaId/localPath/file:// 逐段 percent-encode（与 Dart `Uri.file` 一致）/content:// 透传/在线 url 非空透传/**在线 url null 拒绝（不投射不伪造）**/本地双空拒绝/startPosition 处理/prepare 触发 BUFFERING+切换转发；
- 控制可观察 5：play/pause 驱动 playWhenReady；stop 保留媒体项回 IDLE；seekTo 生效；seekBy 增量；volume/speed 生效；
- 监听桥接与去重 5：状态/isPlaying 按值去重；ENDED→completed 仅一次；mediaId 身份对账；错误文案收敛；未知 duration 不通知；
- release 安全 2：迟到回调（5 类）全部丢弃 + 公开方法安全 + release 幂等；
- 位置流采样 3：播放态 199ms 不写/201ms 写（节流锁死）；暂停态停止采样；空闲态不采样；
- 主线程约束 1：11 个公开方法后台调用全部抛 `IllegalStateException`。

## 3. 构建与测试结果（真实命令与输出）

```
$ cd native && JAVA_HOME=~/dev-tools/jdk-17.0.20.1+1 ./gradlew :app:testDebugUnitTest --rerun-tasks
BUILD SUCCESSFUL
XML 级汇总：40 个测试类，tests=542，failures=0，errors=0，skipped=0
  ├─ PlaybackReducerTest（新增）      140 / 0 / 0
  ├─ PlaybackStoreTest（新增）         33 / 0 / 0
  ├─ ExoPlayerPlaybackEngineAdapterTest（新增） 26 / 0 / 0
  └─ 既有 37 类回归                   343 / 0 / 0

$ cd native && JAVA_HOME=~/dev-tools/jdk-17.0.20.1+1 ./gradlew :app:assembleDebug :app:lintDebug
BUILD SUCCESSFUL（Hilt DI 图含新绑定通过；lint 0 新增 error——92 条既有 issue 由 baseline 收纳）
```

**Robolectric 承载说明**：`PlaybackStoreTest` 原计划纯 JUnit，但 TODO 效果按契约调 `android.util.Log`，AGP mockable jar 默认令其抛 `RuntimeException("Stub!")`（探针测试复现后删除；构建配置不在本阶段允许修改清单）——故以 `RobolectricTestRunner` 承载，**编排断言不依赖 Robolectric 语义**（假引擎 + 虚拟时钟驱动）。

## 4. DSP 与音频处理链路验证

| 项 | 结论 | 证据 |
|---|---|---|
| DSP 挂载方式 | **AudioProcessor 数组**（`DefaultAudioSink.DefaultAudioProcessorChain(ViperMasterProcessor())`），非 AudioSink 包装、非 PCM 回调；仅 `enableViperMaster=true` 时注入；处理链位于 silence-skip/sonic 之前，输入恒 16bit PCM（float 输出已统一关闭） | `AudioEngineFactory.kt:110-130,164-169` |
| DSP 文件 | native 自有移植副本（仅改 package，类体逐字节一致）：`ViperBiquad/ViperMasterChain/ViperMasterProcessor.java` + 控制面 `ViperMasterControl.kt`（当前无生产调用方，仅定义 + 被 AudioEngineFactoryTest 覆盖） | `player/engine/`；12 个 DSP 单测全绿 |
| 音量均衡活跃实现 | **LoudnessEnhancer**（Dart 侧 `_applyGain`：正增益 `setTargetGain`，负增益折进播放器音量，boost≤0 禁用 enhancer 防小米 ROM 音效链叠加） | `audio_service_io.dart:284-285,381-397` |
| **NormalizationGainAudioSink 死代码核查** | **确认死代码**：fork 内定义与 `wrap()` 存在，但全仓无任何 `wrap(` 调用点（唯一相关调用是旧 Flutter 路径直接调静态 `setGlobalGainDb`，不经 wrap 接线）；native 侧仅两处注释引用、未移植 | `AudioEngineFactory.kt:36` 明示；全仓 grep |
| 与 Media3 重复执行风险 | 不存在：DSP 链只在 vendored sink 内一次；音量均衡在 session 上挂 enhancer（Dart 侧），native 侧 T-P1-08 接线时需复核不叠加 | 审计结论 |
| 播放切换资源释放 | 单曲时间线下 prepare 重建时间线，AudioProcessor 随 sink 生命周期（进程级单例，不随切歌重建）；release 时随 sink 销毁 | 适配器 release 测试 |

**DSP 兼容性未验证项**：真实解码下的音质/限幅行为需真机验证（Robolectric 无解码）；跨歌曲的处理器状态重置由 `onFlush/onReset` 保证（单测覆盖 EOS 排空与复位）。

## 5. Rust 边界验证

| 项 | 结论 |
|---|---|
| 启动方 | native 应用**无生产启动方**：`KugouApiService`（loadLibrary + nativeStartNode）与 `KugouServerManager`（五态状态机，18 单测）已就绪，但 `di/KugouServerModule.kt:16` 是空 object（"P0-C 仅结构，无绑定 / TODO(P1)"），仓库/ViewModel 均不消费。当前 Rust 服务器实际由 lite Flutter 壳的 dart:ffi 启动（`lib/main.dart:177`）。**登记：native 版酷狗 API 依赖 Flutter 壳的启动路径，接入新 Store/网络层时需补启动链** |
| 进程模型 | 进程内 tiny_http，监听 127.0.0.1 随机端口 [10000,60000]（port=0 最多重试 10 次）；listener 线程 `kugou-http-listener`；stop 置 AtomicBool 后 join（`server.rs:225-245,263-284`） |
| JNI/FFI 契约 | Rust 本体导出**旧包名死符号** `Java_com_md3music_premium_KugouApiService_native*`（仅 `cfg(target_os="android")`，App 从不绑定）；实际契约 = 纯 C FFI 四件套（`start_server/stop_server/is_server_running/get_server_port`）+ C shim 以正确包名重新导出三符号（`Java_com_gracemusic_kugou_KugouApiService_native*`，零业务逻辑转发 + 入参防护） |
| **panic=abort** | `[profile.release] panic = "abort"`（`Cargo.toml:38-45`，刻意不 strip 防动态导出符号被剥）；`src/` 全仓 **0 处 catch_unwind** → release 下任一 handler 线程 panic = **整个 App 进程 abort，无法同进程捕获** |
| **Rust 测试** | 实测 **65 个 `#[test]`**（src 21 + tests 44）；**沙箱 cargo/rustc 不可用（`~/dev-tools` 仅有未安装的 rustup-init）→ 本阶段未执行、不伪称重新验证**。历史"68"为闸门单测数（见 phase-3-gates-audit.md §0） |
| 后台线程回调风险 | shim 入参防护（env/data_dir NULL、GetStringUTFChars NULL、成对 Release）+ `visibility("default")` 保证进 `.dynsym`；Rust 内部 panic 进程 abort 的残余风险无解——** Rust 保持"可失败子系统"语义（失败退化到"无在线能力"）**（`native-architecture.md:623-630`） |
| 本阶段改动 | **零**。未接 Rust、未改 ABI、未删 JNI 兼容代码。Store 的 `ResolveSongUrl` 效果是未来经网关（`KugouServerGateway`）走 HTTP 数据面的挂点，不经 JNI |

## 6. 音频焦点与生命周期验证

- **焦点运行时未接**（T-P1-08）：Media3 内建 `AudioFocusManager`（`handleAudioFocus=true`，MAIN 角色）vs Dart fork `audioFocusChangeStream` 事件源不同构；fork 改动 #1 暴露的 `AudioFocusEventListener` 获取路径需专门设计。三模式偏好意图已可归约。拔耳机/`becomingNoisy` 由 media3 `setHandleAudioBecomingNoisy(true)` 承担（未真机验证）。
- **生命周期已验证（代码层）**：Store/引擎进程级单例不随 UI 重建；适配器 release 幂等 + 回调全丢弃；Store 不 release 引擎；保活两路驱动幂等。**未验证（真机）**：Activity 销毁不影响播放、杀进程后媒体键唤醒续播、息屏保活（`C.WAKE_MODE_NETWORK`）。

## 7. media3fork 9 处产品级改动核查（本阶段不改 fork）

9/9 均在（9 个文件含 "MD3Music fork" 标记，与 `media3fork/build.gradle.kts:4-13` 声明一一对应）：

| # | 改动 | 位置 |
|---|---|---|
| 1 | AudioFocusManager 焦点事件暴露（package-private→public、三模式开关） | `exoplayer/AudioFocusManager.java:44,166-212` 等 18 处标记 |
| 2 | DefaultAudioSink 缓冲修复（pending inputBuffer 清理与 AudioTrack 初始化解耦，实测 errorCode=1004 驱动） | `exoplayer/audio/DefaultAudioSink.java:1506-1513` |
| 3 | 媒体卡下一首（SEEK_TO_PREVIOUS/NEXT(_MEDIA_ITEM) 常驻命令集） | `exoplayer/ExoPlayerImpl.java:334-342` |
| 4 | vivo 车载歌词/原子随身听/封面 1x1 规避 | `session/legacy/MediaSessionCompat.java:342,4128-4270` 等 14 处 |
| 5 | 原子随身听能力位（VMM_SUPPORT_EVENT_VALUE=31，仅 vivo 家族写入） | `session/LegacyConversions.java:109-112,797` |
| 6 | now playing 手动刷新（refreshNotification） | `session/MediaSessionService.java:635-648` |
| 7 | 前台服务补偿（startForegroundService 被拒时降级 notify） | `session/MediaNotificationManager.java:364-388` |
| 8 | 封面链路诊断日志 | `session/MediaSessionLegacyStub.java:1381-1385` |
| 9 | customActions 暴露（SystemUI 读 PlaybackState customActions） | `session/MediaSessionImpl.java:499-509` |

门禁测试 `AudioEngineFactoryTest.forkCustomizationsRemainAvailable`（反射断言 fork-only API 仍在类路径）全绿；`media3fork` 与 app 的 Maven 边界（排除 exoplayer/session、仅留 common）共同构成防回退双保险。**跨树耦合隔离方案见 phase-2-decisions.md D2-08（三道防线），本阶段保持 third_party/just_audio 零改动。**

## 8. 尚未验证的能力及原因

| 能力 | 状态 | 原因 |
|---|---|---|
| 真机播放（起播/切歌/seek/倍速/音量/循环/随机/睡眠定时全流程） | **未验证** | 沙箱无设备/模拟器；用户真机实测（CI run #11 预构建产物可用） |
| 在线曲目播放 | **阻塞** | T-P1-05 音源解析器未建（`ResolveSongUrl` 效果无执行器）；本地曲目全链路真实可用 |
| Android 7–9（API 24–28）兼容 | **未验证** | lite 侧两项已知缺陷未修复（R1 `MediaStoreScanner.kt:98`；R2 `AudioPlaybackService.kt:621-623`）——D2-09：两项未修复前不得宣称兼容 |
| 后台连续播放/杀进程续播 | **未验证** | 服务层（P1-4）已就绪，真机行为待测 |
| 真实解码下的 DSP 音质 | **未验证** | Robolectric 无解码（测试设计已回避） |
| Rust 行为 | **未重新验证** | cargo 工具链沙箱不可用；本阶段零 Rust 改动 |
