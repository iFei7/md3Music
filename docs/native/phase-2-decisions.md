# 第二阶段 · 决策记录（phase-2-decisions）

> 记录时间：2026-10-13 ｜ 分支 `native` ｜ 每条决策含：结论、依据/证据、影响与后续动作。
> 状态图例：✅ 已生效 ｜ 🔒 长期约束 ｜ 📋 已登记待办

## D2-01 USB 独占输出永久排除 🔒

- **结论**：不恢复、不补回 USB 独占输出功能。
- **依据**：用户 2026-10-12 门禁决议「USB 独占不恢复」；lite 侧移除提交 `62d8b2f`（USB 相关代码已从 lite HEAD 移除）；本阶段任务清单明确排除。
- **影响**：功能迁移矩阵中 USB 相关条目标记「永久排除」；不为此预留接口。

## D2-02 仅做播放缓存，不做离线下载 🔒

- **结论**：本期范围只含**播放缓存**（播放过程中的临时落盘，受容量/清理规则约束）；**不做**离线下载、离线曲库、下载任务管理、断点续传。
- **架构界线**：
  - 播放缓存 ≠ 数据库存储：音频二进制**不进 Room**，走文件缓存（后续实现时定）；
  - 不默认永久保留：须有容量上限与清理规则（LRU/过期）；
  - 不绕过 Rust API、现有鉴权与 `/audio/proxy` 既有行为（该路由按设计返回 403）。
- **缓存实现前必须验证**（前置条件，未验证不得开工）：真实音频 URL 可达性、HTTP Range 支持、缓存策略与容量限制、清理规则、数据来源合法性。
- **依据**：用户 2026-10-12 决议「本期只做播放缓存，不做离线下载」；审计确认当前无成熟离线下载体系。

## D2-03 depth3d flavor 不纳入原生 MVP 🔒

- **结论**：`depth3d` flavor 不进入本期原生 MVP；**保留旧代码与配置，不因本决定删除**。
- **依据**：用户 2026-10-12 决议；审计确认「现有 depth3d flavor 不可编译」（属旧版 Flutter 侧问题，不影响 native 工程，native 侧无 flavor 依赖）。
- **后续**：若未来需要，在 native 侧独立设计 flavor，而非修复旧 Flutter 配置。

## D2-04 新应用独立 applicationId 与独立签名 ✅

- **结论**：applicationId `com.gracemusic.app`、namespace `com.gracemusic`、显示名 Grace；与旧版（`com.md3music.md3music.lite`）**并行安装不冲突**（不同 applicationId）；签名用独立的 `gracemusic` key（RSA 4096，`CN=GraceMusic`，SHA-256 `b8c0edd2…40054`）。
- **签名机制**：本地 `keystore.properties`（gitignored）或环境变量四项 → 装配 release signingConfig；缺签名时 release 构建 **fail-fast**（不产无签名包、不回退 debug 签名）；CI 经 4 个 GitHub Secrets 注入；示例模板 `keystore.properties.example` 可提交。
- **共钥代价（已向用户说明并接受）**：该 key 目前同时签 GraceMusic 与 lite（用户 2026-10-13 决定共用以快速完成 lite 止血）；一旦泄露两应用同时失守，未来拆分需再次付出「卸载重装」代价。lite 旧 key 已公开泄露、永久视为弃用。
- **依据**：用户 2026-10-12 身份 10 项要求 + 2026-10-13 三项确认（push 解决密钥、显示 Grace/全称 GraceMusic、不做导出）。

## D2-05 远程崩溃上报暂缓，先建本地诊断基础 🔒

- **结论**：本期不默认接入远程崩溃上报；先建立必要的本地诊断能力（日志、构建期检查、lint 基线等）。
- **依据**：用户 2026-10-12 决议「暂不默认接入远程崩溃上报」。
- **后续**：P6 收尾期评估接入方案（需单独评审隐私与合规）。

## D2-06 /user 路由暂不进入原生主导航 📋

- **结论**：`/user` 不作为原生主导航入口；保留第一阶段兼容性调查结论，9 路由中 `user` 目前仅为占位屏。
- **依据**：用户 2026-10-12 决议「/user 保留兼容」+ 「暂不作为原生主导航入口」。
- **后续**：账号体系与 /user 的真实形态在 P4 功能移植前完成调查再定。

## D2-07 主题键统一迁移策略 📋

- **规范键**：`settings_theme_mode`；**兼容键**：`theme_mode`（仅按兼容迁移需要处理）。
- **迁移规则**（落地时执行）：
  1. 先核实旧版实际读写路径与数据格式（未经核实不得覆盖旧版设置）；
  2. 优先保留有效规范键值；仅当规范键缺失时读兼容键；
  3. 两键都不存在 → 采用系统默认主题；
  4. 必须测试冲突、缺失、非法值三种用例。
- **当前状态**：native 侧主题开关**尚未接 DataStore**（`MainActivity.kt:24-27` TODO，`dynamicColor`/`oledBlack` 默认 false）——本策略在 DataStore 接线时一并落地。
- **依据**：用户 2026-10-12 决议「settings_theme_mode 作为主题设置的规范键」。

## D2-08 media3fork 跨树耦合处理计划 🔒📋

- **结论**：media3 必须继续使用 `:media3fork`（vendored 源码，srcDirs 指向 `third_party/just_audio`），**严禁**退回 Maven 版；跨树耦合以「清单化 + 门禁 + 变更评审」控制，移除时机在播放核心稳定后评估。
- **9 处产品级改动实证清单**（全树 40+ 处 `MD3Music fork` 标记 + 1 处 `MD3Music:`，分布于 8 个文件）：

| # | 改动 | 位置 |
|---|---|---|
| 1 | 焦点事件暴露（package-private→public，三模式焦点开关） | `exoplayer/AudioFocusManager.java:44,166-212` |
| 2 | DefaultAudioSink 缓冲修复（pending inputBuffer 清理与 AudioTrack 初始化解耦，实测 errorCode=1004 驱动） | `exoplayer/audio/DefaultAudioSink.java:1506-1514` |
| 3 | 媒体卡下一首（SEEK_TO_PREVIOUS/NEXT/NEXT_MEDIA_ITEM 常驻命令集） | `exoplayer/ExoPlayerImpl.java:334-341` |
| 4 | vivo 车载歌词/原子随身听/封面 1x1 规避 | `session/legacy/MediaSessionCompat.java:342,4128-4239` |
| 5 | 原子随身听能力位（VMM_SUPPORT_EVENT_VALUE=31，仅 vivo 家族写入） | `session/LegacyConversions.java:109-111,797-802` |
| 6 | now playing 手动刷新（refreshNotification） | `session/MediaSessionService.java:636-647` |
| 7 | 前台服务补偿（startForegroundService 被拒时降级 notify） | `session/MediaNotificationManager.java:369-380` |
| 8 | 封面链路诊断日志 | `session/MediaSessionLegacyStub.java:1381` |
| 9 | customActions 暴露（SystemUI 读 PlaybackState customActions） | `session/MediaSessionImpl.java:503-505` |

- **必须保留**：全部 9 处（各自有产品级动因：vivo 车载、焦点策略、缓冲稳定性、媒体卡按键、前台服务补偿等）。
- **防「lite 更新静默改变 native 行为」**：① `third_party/just_audio` 的任何变更必须经 native 侧评审（fork 标记完整性核查：`grep -rn "MD3Music fork"` 计数比对）；② 门禁测试 `AudioEngineFactoryTest.forkCustomizationsRemainAvailable` 常驻；③ 上游拉取（upstream=zzyoxml/md3Music）后必须复跑 343 单测 + 比对 fork 标记数。
- **移除跨树源码依赖的时机与验证**：播放核心（P1 剩余 + P5）稳定、且 fork 改动可被独立维护的 fork 仓或上游 PR 承载后，再评估「fork 独立成仓/模块」；移除时以「9 处改动逐条对照 + 单测 + 真机播放回归」验证，**不得**以「能编译」作为通过标准。

## D2-09 Android 7–9 专项验证计划 📋

- **结论**：minSdk 24 为硬约束；本阶段完成静态兼容核查（4 处 SDK_INT 守卫、Robolectric 双 sdk 成对测试、lint 基线），**真机 Android 7–9 行为未验证**，以下两项登记为后续必修：
  1. **MediaStoreScanner.kt:98 RELATIVE_PATH**（lite 侧）：Android 7–9 本地扫描返回空。修法：改 `getColumnIndex` + 列缺失分支（参照同函数 bitrate 列写法），native 侧移植本地扫描时直接采用修法。
  2. **SuperLyricHelper.registerPublisher() catch(Exception)**（lite 侧 AudioPlaybackService.kt:621-623）：改 `catch(Throwable)` 或依赖存在性判断；native 侧若引入 SuperLyric 必须一开始就用正确写法。
- **验证矩阵（后续执行）**：Android 7.0 / 8.x / 9 真机或模拟器各一台，冒烟项 = 安装启动、主题、通知渠道创建、本地媒体扫描（修 1 后）、SuperLyric 注册（修 2 后）、播放起播/锁屏控制。
- **纪律**：两项未修复前，**不得**宣称 Android 7–9 全面兼容。

## D2-10 本阶段工程变更范围（边界声明）

- 允许：构建/配置类文件（`*.gradle.kts`、lint 基线、示例配置、文档）。
- 禁止（本阶段未做）：业务源码改写、lite 分支任何改动、Rust 服务重写、Flutter 页面迁移、完整播放器/Dock/歌词/队列/下载。
- 提交纪律：只提交本地，不推送；提交前过 `git diff --check` 与未跟踪文件核查；无密钥/密码/令牌/构建产物入库。
