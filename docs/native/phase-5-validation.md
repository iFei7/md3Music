# 第五阶段 · 验证报告（phase-5-validation）

> 本报告记录第五阶段（T-P1-13 离线歌单播放）的**实际执行**验证命令、退出码与结果。
> **纪律**：所有「通过」均附命令与可复算的数字；未执行的项一律标注「未执行」，
> **不以「编译成功」替代验收**，不估算。

---

## 0. 环境与基线

| 项 | 值 |
|---|---|
| 仓库 | `C:/Users/hwx1254427/WorkBuddy/md3Music-native`（工程在 `native/`） |
| 分支 | `native` |
| 执行前 HEAD | `e1265c1b6708795a3cf2c2295214129b467f508b`（第四阶段 T-P1-04 + T-P1-06） |
| 执行前工作区 | 含**未提交**的离线歌单播放实现（`player/offline/` 等）——本阶段在其上继续 |
| JDK | `~/dev-tools/jdk-17.0.20.1+1`（AGP 9 需 JDK17） |
| SDK | `~/dev-tools/android-sdk`（`native/local.properties` 指向本机路径，被 `.gitignore` 排除） |
| 本阶段开工单测基线 | **690 / 0 失败 / 0 错误 / 0 跳过**（`e1265c1` 状态，`--rerun-tasks` 实测） |
| 真机 / 模拟器 | **无**（沙箱无设备） |
| Rust 工具链 | `cargo` **未安装**（`which cargo` → not found），故未执行任何 Rust 测试；本阶段 Rust 源码零改动 |

---

## 1. 逐项命令与结果

| # | 命令 | 退出码 | 结果 |
|---|---|---|---|
| 1 | `./gradlew :app:testDebugUnitTest --rerun-tasks` | 0 | BUILD SUCCESSFUL；**suites=54 / tests=772 / failures=0 / errors=0 / skipped=0** |
| 2 | `./gradlew :app:assembleDebug` | 0 | BUILD SUCCESSFUL |
| 3 | `./gradlew :app:lintDebug` | 0 | BUILD SUCCESSFUL；报告 `app/build/reports/lint-results-debug.html` |
| 4 | `./gradlew :app:assembleDebugAndroidTest` | 0 | BUILD SUCCESSFUL（androidTest 编译门禁） |

> 命令 1-4 合并为一次 Gradle 调用执行（`./gradlew :app:testDebugUnitTest --rerun-tasks :app:assembleDebug :app:lintDebug :app:assembleDebugAndroidTest`），退出码 0。
> AGP 9.0.1 **无 `testReleaseUnitTest` 任务**，单测一律使用 `:app:testDebugUnitTest`。

### 1.1 单测增量（可复算）

| 阶段 | 测试数 | 增量 |
|---|---|---|
| 本阶段开工基线（`e1265c1`） | 690 | — |
| `player/offline/*Test`（5 文件：`OfflineAdvancePolicyTest` 9 / `PlaybackCacheStoreTest` 18 / `SimplePlaybackCacheResolverTest` 9 / `AndroidNetworkAvailabilityProviderTest` 8 / `PlaybackCacheEngineWiringTest` 7） | 741 | +51 |
| `player/store/OfflineAdvanceStoreTest.kt`（Store 层集成，27 条） | 768 | +27 |
| 缺陷修复回归 + 归约器补测（`PlaybackReducerTest` +4） | **772** | +4 |

`suites` 由 48 → 54。**无既有测试被删除、弱化或跳过**（`skipped=0`）。

### 1.2 lint 结果核验

`:app:lintDebug` 输出：`Lint found 2 warnings (and 3 errors and 88 warnings filtered by baseline lint-baseline.xml)`。

可见的 2 条告警**均落在本阶段未改动的文件**，属既有告警：

| 告警 | 位置 | 是否本阶段引入 |
|---|---|---|
| `NewerVersionAvailable`（okhttp 4.12.0 → 5.5.0） | `native/gradle/libs.versions.toml:23` | **否** |
| `UseKtx`（建议用 `SharedPreferences.edit` KTX 扩展） | `native/app/src/main/kotlin/com/gracemusic/data/source/LoudnessStorePrefs.kt:45` | **否**（T-P1-05 交付文件） |

**`app/lint-baseline.xml` 未被修改**（`git status` 无该文件；未通过扩大 baseline 隐藏新增问题）。

> 说明：本阶段新增文件 `player/offline/ResolvedSourceMemory.kt` 初版用 `prefs.edit().putString(..).apply()`，
> 触发一条**新增** `UseKtx` 告警（可见告警由 2 → 3）。已改用 core-ktx 的 `prefs.edit { putString(..) }`
> （默认 `commit=false`，语义等价），**新增告警归零**，可见告警回到 2 条。

---

## 2. 开发过程中的失败与修复（如实记录）

| # | 阶段 | 现象 | 处置 |
|---|---|---|---|
| 1 | 实现期（缺陷 D1） | 离线命中缓存候选后的「回写记忆源」**不生效**，候选曲 `url == null` 时**击穿 R-1/R-2**（明明有已缓存曲却停播并报「网络不可用，歌单中无已缓存歌曲」）。根因：`Song.equals` 仅比 `id`（`Song.kt:123-127`）→ 纯字段级更新使 `state.copy(queue = updated)` 与旧 state 结构性相等 → `PlaybackStore.apply` 的 `_state.value = transition.state` 被 `MutableStateFlow` 相等去重**吞掉**；随后 `PlayAt` 读到 `url == null` → `needsUrlResolution` 为真 → `ResolveSongUrl`（离线必失败）。 | **已修复**：把「回写」与「起播」合并为一次状态迁移——`PlaybackIntent.PlayAt(index, source = null)` + `PlaybackReducer.playAt(state, index, source)` + `PlaybackStore.playCachedCandidate` 单次派发。探针实证见 §2.1。 |
| 2 | 实现期（缺陷 D2） | `startOfflineAdvance` 的候选探测**无短路**，命中后仍探测后续候选（`resolveCalls=[b, c, d]`），与 `OfflineAdvancePolicy` KDoc 声明的「惰性短路由调用方保证」不符，且产生无谓磁盘 I/O。 | **已修复**：命中首个可播缓存即 `break`（`resolveCalls` 收敛为 `[b, c]`，`choose` 仍取候选序首个命中，决策结果不变）。 |
| 3 | 实现期（歧义 D3） | `OFF` 模式起始位即队尾时，离线枚举会**绕回队首方向**（`nextCandidateIndices` 的 `(_currentIndex + 1) % n` 语义），与初版设计稿「OFF 到队尾即止」的措辞不符。 | **判定为符合需求**（需求原文「**循环到**歌单下一首已缓存歌曲，**若存在可播放的缓存歌曲则继续播放，若无任何可播放的歌曲则停止播放」= 全歌单**存在性**判定）。故**保持**绕回，改为修正 KDoc 的错误描述，并把该行为**锁为显式契约测试** `OFF_离线队尾_绕回队首方向命中已缓存曲并起播`。 |
| 4 | 测试基建 | 首版测试引用 `PlaybackStoreTest` 的 fake 时发现其为 `private` 嵌套类（同包不可见）。 | 按项目既有约定（`HighFrequencyChannelTest` / `RecoveryOrchestratorTest` 亦各自私有 fake）新建最小 fake，**未复制整个 Harness**。 |

**无一轮以放宽断言、删除用例或屏蔽错误收尾。**

### 2.1 D1 修复实证（同一探针，回退生产改动 vs 修复后）

| 场景 | 修复前 | 修复后 |
|---|---|---|
| 候选曲 `url == null`（真实形态） | `engine.calls=[prepare:a:null:true, pause]`、`resolveError=网络不可用且歌单中无已缓存歌曲`、`queue.playlist[2].url=null`、`resolveCalls=[b, c, a, b]`（首轮命中 c 但回写被吞 → `ResolveSongUrl` 失败 → 恢复链二次枚举） | `engine.calls=[prepare:a:null:true, prepare:c:null:true]`、`resolveError=null`、`queue.playlist[2].url=https://cdn.example/c` |
| 候选曲 `url` 为陈旧值 | `prepare:c:url=<旧值>`（回写未生效） | `prepare:c:url=<记忆源>` + 队列项 url 已回写 |

对应回归用例：`R1_R2_离线前进回写记忆源生效_候选url为空时以记忆源起播`、
`R1_R2_离线前进_候选url为陈旧值_以记忆源起播并回写队列项`。

---

## 3. 未执行 / 未验证项（明确列出）

| 项 | 原因 | 归属 |
|---|---|---|
| 真机断网时在线歌单的跳缓存曲行为与缓存命中率 | 沙箱无设备 | 用户实测 |
| 真机「网络恢复后不自动续播」（含通知栏 / 媒体键路径） | 沙箱无设备 | 用户实测 |
| `SimpleCache` 在真机文件系统上的索引加载耗时与主线程影响 | 沙箱无设备 | 用户实测 |
| `ConnectivityManager` 在 OEM 定制 ROM 上的判定表现 | 沙箱无设备 | 用户实测 |
| Android 7–9（API 24–28）兼容性 | 无设备 | 用户实测 |
| 「非空队列 + `currentIndex` 越界」分支 | 公开 API 无法构造，属防御性代码 | 不适用 |
| 听书付费章节的离线专项断言 | 该守卫在 `RecoveryOrchestrator.maybeAutoSkip`（错误驱动、与离线无关），离线前进不经过它，断言不可达 | 不适用 |
| Rust 侧测试 | `cargo` 未安装 | 环境阻塞（本阶段 Rust 零改动） |

---

## 4. 结论

- **代码层**：T-P1-13 已实现并有单测覆盖（本阶段新增 **82** 条：690 → 772）；全量单测 772 全绿，
  Debug 构建、lint、androidTest 编译门禁全部通过；lint 无新增可见告警、baseline 未动。
- **实现期发现并修复 2 个真实缺陷**（D1 回写被 `MutableStateFlow` 去重吞掉、D2 候选探测无短路），
  均由回归用例锁定；1 处歧义（D3 OFF 队尾绕回）经复核需求原文判定为**符合需求**，已锁为契约测试。
- **真机层**：**完全未验证**。所有「离线播放 / 缓存命中 / 网络恢复不续播」的真机可用性声明
  **一律不成立**，须待用户设备实测。
- **未完成项**：缓存大小设置接线（F-CACHE-009）、缓存索引迁移（`StandaloneDatabaseProvider`）、
  源记忆加密、`Previous` 方向缓存过滤、`AppForegroundChanged` 生产者 —— 详见
  `docs/native/phase-5-offline-playlist.md` §10。
- **阶段边界**：T-P1-07 / T-P1-08 / T-P1-09 / T-P1-10 / T-P1-11 / P2 / P3 **均未实现**（本阶段未越界）；
  未引入 USB 独占、离线下载、下载队列、断点续传或 `depth3d`。
