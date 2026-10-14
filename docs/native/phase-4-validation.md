# 第四阶段 · 验证报告（phase-4-validation）

> 本报告记录第四阶段（T-P1-04 + T-P1-06）的**实际执行**验证命令、退出码与结果。
> **纪律**：所有「通过」均附命令与可复算的数字；未执行的项一律标注「未执行」，**不以「编译成功」替代验收**，不估算。

---

## 0. 环境与基线

| 项 | 值 |
|---|---|
| 仓库 | `C:/Users/hwx1254427/WorkBuddy/md3Music-native`（工程在 `native/`） |
| 分支 | `native` |
| 执行前 HEAD | `a0656b6f18c8788beeefe8777f9982557618ec54`（`feat(native): build main shell with glass dock (P3-A)`） |
| 执行前工作区 | 干净（`git status --short --branch` → `## native...origin/native`，无改动） |
| JDK | `~/dev-tools/jdk-17.0.20.1+1`（AGP 9 需 JDK17） |
| SDK | `~/dev-tools/android-sdk`（`native/local.properties` 指向本机路径，被 `.gitignore` 排除） |
| 执行前单测基线 | **656 / 0 失败 / 0 错误 / 0 跳过**（`--rerun-tasks` 实测，`suites=46`） |
| 真机 / 模拟器 | **无**（沙箱无设备） |
| Rust 工具链 | `cargo` **未安装**（`which cargo` → not found），故未执行任何 Rust 测试；本阶段 Rust 源码零改动 |

---

## 1. 逐项命令与结果

| # | 命令 | 退出码 | 结果 |
|---|---|---|---|
| 1 | `./gradlew projects` | 0 | BUILD SUCCESSFUL；工程层级 `:app` + `:media3fork` |
| 2 | `./gradlew :app:testDebugUnitTest --rerun-tasks` | 0 | BUILD SUCCESSFUL；**suites=48 / tests=690 / failures=0 / errors=0 / skipped=0** |
| 3 | `./gradlew :app:assembleDebug` | 0 | BUILD SUCCESSFUL |
| 4 | `./gradlew :app:lintDebug` | 0 | BUILD SUCCESSFUL；报告 `app/build/reports/lint-results-debug.html` |
| 5 | `./gradlew :app:assembleDebugAndroidTest` | 0 | BUILD SUCCESSFUL（androidTest 编译门禁） |

> 命令 3/4/5 合并为一次 Gradle 调用执行（`./gradlew :app:assembleDebug :app:lintDebug` 与 `:app:assembleDebugAndroidTest`），退出码 0。
> AGP 9.0.1 **无 `testReleaseUnitTest` 任务**，单测一律使用 `:app:testDebugUnitTest`。

### 1.1 单测增量（可复算）

| 阶段 | 测试数 | 增量 |
|---|---|---|
| 执行前基线 | 656 | — |
| T-P1-04 后 | 673 | +17（`HighFrequencyChannelTest`） |
| T-P1-06 后（最终） | **690** | +17（`RecoveryOrchestratorTest` 15 + 适配器错误透传 2） |

`suites` 由 46 → 48（新增两个测试类）。**无既有测试被删除、弱化或跳过**（`skipped=0`）。

### 1.2 lint 结果核验

`:app:lintDebug` 输出：`Lint found 2 warnings (and 3 errors and 88 warnings filtered by baseline lint-baseline.xml)`。

新增可见的 2 条告警**均落在本阶段未改动的文件**，属既有告警：

| 告警 | 位置 | 是否本阶段引入 |
|---|---|---|
| `NewerVersionAvailable`（okhttp 4.12.0 → 5.5.0） | `native/gradle/libs.versions.toml:23` | **否**（本阶段未改该文件） |
| `UseKtx`（建议用 `SharedPreferences.edit` KTX 扩展） | `native/app/src/main/kotlin/com/gracemusic/data/source/LoudnessStorePrefs.kt:45` | **否**（T-P1-05 交付文件，本阶段未改） |

**`app/lint-baseline.xml` 未被修改**（`git status` 无该文件；未通过扩大 baseline 隐藏新增问题）。

---

## 2. 与「本次引入问题 / 历史问题 / 环境问题」的区分

| 类别 | 项 | 判定 |
|---|---|---|
| 本次引入 | 无。全部命令退出码 0，单测 0 失败 | — |
| 历史遗留 | 上述 2 条 lint 告警（okhttp 版本 / KTX 建议） | 既有，本阶段未触碰相关文件 |
| 环境限制 | ① 无 Android 设备/模拟器 → 真机验证全部未执行；② `cargo` 未安装 → Rust 测试未执行（本阶段 Rust 零改动）；③ 沙箱 cmake 3.22.1 不可用（原生 so 构建走 `ndk-build`，本阶段未触发） | 如实登记，不伪装 |

**开发过程中的失败与修复（如实记录）**：T-P1-06 子任务经 3 轮验证循环——① 编译失败（测试内嵌类可见性、`cancel` 未导入）→ 修复；② 3 个测试失败 → 修复（其中暴露 1 处**真实实现缺陷**：在途恢复期间的重复错误会提前释放令牌导致退避链断裂，见 phase-4-recovery.md §5）；③ 全绿。**无一轮以放宽断言或屏蔽错误收尾。**

---

## 3. 未执行 / 未验证项（明确列出）

| 项 | 原因 | 归属 |
|---|---|---|
| 真机在线起播、弱网恢复、断网→恢复、连续解析失败跳歌 | 沙箱无设备 | 用户实测 |
| 真机睡眠定时倒计时走字与切后台行为 | 沙箱无设备 | 用户实测（T-P1-09 后一并） |
| Android 7–9（API 24–28）兼容性 | 无设备；且 R3-03 两项已知缺陷未修复 | 用户实测 |
| 后台播放 / 杀进程续播 | 无设备 | 用户实测 |
| Rust 侧测试 | `cargo` 未安装 | 环境阻塞 |
| 恢复超时看门狗 20s 阈值手感、退避 30/60/120s 实际手感 | 无设备 | 用户实测 |
| HTTP 状态码反射提取在 R8 混淆后的可用性 | 无设备 | 用户实测 |

---

## 4. 结论

- **代码层**：T-P1-04 与 T-P1-06 均已实现并有单测覆盖；全量单测 690 全绿、Debug 构建、lint、androidTest 编译门禁全部通过。
- **真机层**：**完全未验证**。所有「在线播放 / 后台播放 / 恢复能力」的真机可用性声明**一律不成立**，须待用户设备实测。
- **未完成项**：T-P1-07 / T-P1-08 / T-P1-09 / T-P1-10 / T-P1-11 / P2 / P3 均未实现（本阶段未越界）。
