# 第三阶段 B · 音源解析器（T-P1-05）与网络层桩级落地

> **任务**：路线图 T-P1-05（`/song/url` 降级链 + 响度缓存）+ T-P2-05 桩级（网络层"可先桩"条款）。
> **双基准**：lite（`kugou_api_client.dart`，语义 1:1 对齐）+ Sonify（`github.com/iFei7/Sonify`，GPL-3.0——**仅借鉴工程思路，代码全部重写**，无一行复制）。
> **基线**：`b606d87`（542 单测）。**本阶段后**：**631 单测全绿**（+30 网络层 +50 解析器 +9 接线），assembleDebug 通过。

---

## 1. 在线播放链路（本任务打通的核心）

```
装载/RetryCurrent/SetAudioQuality（在线曲，url==null）
  → 归约器 ResolveSongUrl(song) + isResolvingUrl=true
  → Store 执行器（@StoreScope launch，主线程派发不受阻）
      请求音质 = state.audioQuality.value（API 码字符串）
  → SongUrlResolver.resolve
      三分流：本地直返 / 云盘先 /user/cloud/url 失败回退链 / 在线降级链
      降级链：viper_tape→[viper_tape,high,flac,320,128]；high→[high,flac,320,128]；
              flac→[flac,320,128]；320→[320,128]；其他→[128]
      链驱动：单档 null/空url/isTrial 跳过；回写档==请求档精确命中即返；
              否则按 qualityRank 留 best；本地失败(busy/unavailable)中止整链；
              45s 总超时；兜底三段 best→ppage_id(非试听)→standard+downgrade(试听接受)→Failure
      成功即写 LoudnessCache（lufs 非空且有限才写）
  → Success → dispatch(UpdateSong(song.copy(url), actualQuality=回写档))
      归约器回写环：当前曲 → 清 isResolvingUrl + 写 actualPlayingQuality(F-SRC-006)
                    + Prepare(当前位置, playWhenReady=awaiting) → engine.prepare
      非当前曲（迟到回写）→ 纯写写（不重备、不碰新曲）
  → Failure → dispatch(EngineError(安全文案)) → resolveError 上屏
```

## 2. 文件清单

| 文件 | 职责 | 测试 |
|---|---|---|
| `data/net/KugouApi.kt` | 冻结契约：接口 + SongUrlRequest/Attempt/CloudUrlRequest/Attempt/LocalFailureKind | — |
| `data/net/OkHttpKugouApi.kt` | OkHttp 直连本机 Rust（connect 10s/read 15s）；懒启动+就绪等待 ≤8s；**路径逐段拼接**（防 %2F 404，Sonify 教训）；buy→standard 内部重试（先于 url 检查）；无 url→free_part 试听一次；别名解析（url/play_url、quality 默认 '128'、isTrial 双条件、响度双别名、data 层缺失回根）；503 local_server_busy→SERVER_BUSY；回环连接错→SERVER_UNAVAILABLE；CancellationException 重抛 | `OkHttpKugouApiTest` 30（MockWebServer） |
| `data/source/SongUrlResolver.kt` | 降级链 + 链驱动 + 三段兜底 + 三分流（45s 超时可注入）；响度写入 | `SongUrlResolverTest` 34（假 API） |
| `data/source/LoudnessCache.kt` + `LoudnessStorePrefs.kt` | url→(lufs,peak)；300 条插入序淘汰、更新刷新序；SP 持久化（key `kugou_url_loudness` 语义、独立文件 `kugou_loudness`）；warmUp 一次性；损坏 JSON 容错 | `LoudnessCacheTest` 16 |
| `kugou/di`（`KugouServerModule.kt` 填实） | NativeKugouServerGateway / KugouServerManager（dataDir=filesDir）/ KugouApi / LoudnessStore / LoudnessCache 绑定——**Rust 服务器生产启动链就此打通**（此前 TODO(P1) 空骨架，native 曾依赖 lite Flutter 壳 dart:ffi 启动） | Hilt 编译门禁 |
| `player/state/PlaybackIntent.kt` | `UpdateSong` 增可选参 `actualQuality: String? = null`（词汇表第二处增补，KDoc 登记） | — |
| `player/store/PlaybackReducer.kt` | `updateSong` 回写分支写 `actualPlayingQuality`（null 保持现值防误清） | +3 |
| `player/store/PlaybackStore.kt` | ResolveSongUrl 执行器（scope.launch → resolve → 回写/报错）+ init `loudnessCache.warmUp()` | +6 |
| `gradle/libs.versions.toml` + `app/build.gradle.kts` | 仅新增 `okhttp-mockwebserver`（testImplementation，复用 okhttp 4.12.0 版本号） | — |

## 3. 与 lite 的刻意偏离（全部 KDoc 登记）

| 偏离 | 原因 | 归属 |
|---|---|---|
| 20028 设备重注册、20018 token 刷新、VIP `/song/url/new` 通道不实现 | native 无会话/登录层（T-P2 数据层） | T-P2-07 |
| qualityRank 非法回写档按"无证据"处理（不参与 best 竞争），lite 记 0 | 采 Sonify「没有证据就不猜」纪律，防"假 Hi-Res" | 保持 |
| 解析失败不自动跳下一首（lite `_resolveError` 后 auto-next） | 自动恢复链未建；错误已上屏 | T-P1-06 |
| 本地 `content://` 不做 MediaStore 真实路径解析（lite 有） | 本地音乐模块未建；适配器已透传 content:// | F-LIB |
| firstUrl 判空口径收紧（空串/空 List 视为无 url，lite 会误判） | 语义等价纠偏 | 保持 |
| 纯写写回写（迟到 url/NAS localPath）因 `Song.equals` 仅按 id + StateFlow 相等合并，不落状态流 | 既有 MVI 语义；url 缓存价值受限（重复播放多一次解析，无害） | 与 T-P1-10 一并复审 |

## 4. 响度缓存与 F-SRC-008

真机上酷狗 `/song/url` **常不返回响度字段**（lite 实测记录，相邻曲目原始响度差可达 13.7dB）→ 本缓存在真机常空属**预期**，不伪造。已就绪的消费挂点：`LoudnessCache.loudnessForUrl(url)`（读取优先级 song.loudnessLufs → 缓存，对位 lite `setUrl` 路径），待音量均衡接线任务（T-P5-02/D-11 LoudnessEnhancer 等价落地）消费。

## 5. Sonify 参考采纳清单（GPL-3.0 合规声明）

采纳（思路级）：路径逐段拼接教训、CancellationException 一律重抛、「没有证据就不猜」、测试注入（seed*ForTest 式）与方法名即断言的测试组织、非 2xx 也要读错误体。未采纳：MMKV/object 单例/负缓存/能力表/可播性表/媒体插桩（后续迭代候选）。**无代码复制**；GraceMusic 许可证策略不受影响。

## 6. 测试与验证

```
:app:testDebugUnitTest（--rerun-tasks 实测）→ 43→44+ 套件，tests=631，failures=0，errors=0，skipped=0
:app:assembleDebug / :app:lintDebug → BUILD SUCCESSFUL
构成：542 基线 + OkHttpKugouApiTest 30 + SongUrlResolverTest 34 + LoudnessCacheTest 16
      + 归约器/Store 接线 9 = 631
```

MockWebServer 专项覆盖：参数编码（含 %2F 回归）、别名全表、buy 重试矩阵（含"首响应故意带 url+buy"的抢跑回归）、downgrade 矩阵、试听矩阵、503/连接错分流、懒启动链（真 Manager+FakeGateway 断言 dataDir 透传）、就绪等待超时。

## 7. 真机验证项（预发布实测清单）

1. 在线曲目起播（降级链真实命中 + 实际音质上屏与请求档降级提示）；
2. 云盘曲目起播（/user/cloud/url 先行）；
3. 试听片段（30s）体验与上屏；
4. Rust 服务器 JNI 启动链（dlopen→监听）与首次解析延迟（懒启动 + 8s 就绪窗）；
5. 付费/版权受限曲目 → 「暂无可用音源」上屏（不自动跳歌为已知差异）；
6. 弱网 45s 总超时行为；
7. 响度字段缺失时无异常（缓存常空路径）。

## 8. 发布

推送 origin/native → CI（native.yml）：build（签名 release APK）+ test（Android JVM 门禁 + Rust 观测项）→ release job 自动创建 **prerelease**（tag `v1.0.0-grace-native-<sha7>`，资产 `GraceMusic-native-v1.0.0-grace-<sha7>.apk`）。
