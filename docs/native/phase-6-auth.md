# 第六阶段 · 账号与登录链路（phase-6-auth）

> 任务：**T-P2-04**（加密 token 存储）+ **F-NET-003**（Authorization 注入）+ **F-ACC-005**（登录编排数据层）
> 交付提交：见「Git」节
> 关联矩阵项：T-P2-04、F-PERS-003/004、F-ACC-001~011、F-NET-003、F-STAT-007/008
> 交付策略：**OMO 编排 + ECC 门禁**（4 个子任务：S1 加密存储 / S2 登录 API 契约 / S3 鉴权注入与账号仓库 / S4a DI 闭环）

---

## 1. 背景与范围界定

### 1.1 为什么现在做
此前 native **无账号体系**，已登记为连带偏离：
1. `RecoveryOrchestrator.kt:93` —— 「Dart 用 `!apiClient.isLoggedIn`；native 无会话层」，故 `authenticationRequired` 恒 `false`，改用 media3 的 `ERROR_CODE_AUTHENTICATION_EXPIRED` 近似；
2. T-P1-05 音源解析器 —— **20028 / 20018 / VIP 通道不实现**（无会话层）。

### 1.2 本阶段范围（**只做数据层，不做 UI**）

| 做 | 不做（归后续） |
|---|---|
| 加密 token 存储（按 userid 隔离） | **LoginPage 三 tab UI**（T-P4-11，归 P4） |
| 登录 API 契约层（10 个方法） | 我的页登录态分支 / 播放需登录弹窗（F-STAT-007/008） |
| Authorization / apicache 绕过 / dfid 注入 | 音质降级链的 VIP 通道解锁（20028/20018） |
| `AccountRepository` 登录编排 + StateFlow 登录态 | `RecoveryOrchestrator` 的登录态判定接入 |
| DI 闭环（Hilt 图编译通过） | 真机三种登录方式验证 |

**这是一次有意识的「先数据层、后 UI」切分**：数据层可单测覆盖（MockWebServer + 假 TokenStore），UI 依赖 Compose 页面与真机登录，混在一期会拖长验证链。

---

## 2. 契约审计（派发前只读核实）

### 2.1 lite 侧（对位源）
`lib/services/kugou_api/kugou_api_client.dart`

| 事实 | 行号 |
|---|---|
| `Authorization = token=<t>;userid=<u>[;vip_token=<v>]`（分号连接，服务端按 `;` 切 cookie） | :263-267 |
| `/images` **不注入** token/dfid 且移除已有 Authorization（否则上游缺 `imgs` 字段） | :259, :274-275, :278-280 |
| 已认证请求加 `x-apicache-bypass: 1` + `Cache-Control: no-cache`（Rust apicache 的 key 不含 token，切账号会串号） | :268-272 |
| `dfid` 走 **query** 参数 | :278-280 |
| token 加密存储、userid/账号列表走普通 prefs | :650-651 |
| 键 `kugou_token_$uid` / `kugou_vip_token_$uid` / `kugou_current_userid` | :660-663 |
| 多账号 `error_code=34175` → 读 body 的 `data.info_list` | `_getAllowNonOk` |

登录方法（:3295-3500）：`loginByCellphone` / `loginByUsername` / `getLoginQrKey` / `createLoginQr` / `checkLoginQr` / `refreshLogin` / `sendLoginCaptcha` / `sendCaptcha`（重复定义）/ `loginByOpenplat` / `createLoginWx` / `checkLoginWx` / `getUserDetail`。
dfid：`registerDevice()` :836-847（每次冷启动无参 GET `/register/dev`，dfid 取 `data.dfid`）；prefs 键 `kugou_dfid` :624；**登出不删 dfid**（:598 注释「保留 kugou_dfid，非机密」）。

### 2.2 Rust 侧（服务端已就位，**本阶段零改动**）
`kugou_api_server/rust/src/modules/mod.rs:80-90,122,188,247` 已注册 12 条登录相关路由：
`/login/wx/create`、`/login/wx/check`、`/login/qr/create`、`/login/qr/check`、`/login/qr/key`、`/login/token`、`/login/device/kick`、`/login/device`、`/login/openplat`、`/login/cellphone`、`/login`、`/register/dev`、`/user/detail`、`/captcha/sent`。

---

## 3. 交付内容

### 3.1 S1 加密 token 存储（T-P2-04）

**`data/secure/TokenStore.kt`**（新增）
- `data class KugouCredentials(userid, token, vipToken: String?)` —— **显式覆盖 `toString()`** 返回脱敏串（防误打印泄露）。
- `interface TokenStore`：`load(userid): KugouCredentials?` / `save(credentials)` / `clear(userid)` / `currentUserid(): String?` / `setCurrentUserid(userid?)`，全 `suspend`（磁盘 I/O 禁止主线程）。
- `class EncryptedSharedPreferencesTokenStore`：
  - **MasterKey**：`MasterKey.Builder(context).setKeyScheme(AES256_GCM)`（security-crypto 1.1.0 新 API，旧 `MasterKeys.AES256_GCM_SPEC` 已 deprecated），别名走库常量，源码无硬编码密钥；
  - **两张 prefs 分立**：加密 `gracemusic_secure_credentials`（`kugou_token_$uid` / `kugou_vip_token_$uid`）+ 普通 `gracemusic_account`（`kugou_current_userid`，非机密）；
  - **绝不抛异常**：`GeneralSecurityException` / `IOException` / `SecurityException` 一律 catch → `null` + `Log.w`（仅含 userid）；
  - 全部 `withContext(Dispatchers.IO)`。

**安全断言（核心）**：`保存后 shared_prefs 下所有 xml 都不含 token 明文` —— 遍历应用私有目录下**所有** prefs XML（含 security-crypto 的 keyset 文件），逐文件断言不含 token 明文，并断言 `load` 读回原值（证明落盘的是合法密文）。

### 3.2 S2 登录 API 契约层

**`data/net/KugouAuthApi.kt`**（新增）—— **刻意不扩展 T-P1-05 冻结的 `KugouApi`**，独立接口避免契约污染与并行冲突。

```kotlin
sealed interface LoginAttempt {
    data class Success(val data: LoginData) : LoginAttempt
    data class AccountChoiceRequired(val accounts: List<LoginAccount>) : LoginAttempt
    data class Failed(val errorCode: Int?, val message: String) : LoginAttempt
    data class LocalFailure(val kind: LocalFailureKind) : LoginAttempt
}
```

10 个方法：`loginByCellphone` / `sendCaptcha` / `createQrLogin` / `checkQrLogin` / **`qrKey`** / `createWxLogin` / `checkWxLogin` / `loginByOpenplat` / `refreshLogin` / `fetchUserDetail`。
`LoginData` / `LoginAccount` 均**显式覆盖 `toString()`** 脱敏（token/vipToken → `***`）。

**`data/net/OkHttpKugouAuthApi.kt`**（新增）—— `_getAllowNonOk` 等价语义（classify 优先级）：

| 优先级 | 判据 | 结果 |
|---|---|---|
| 1 | `error_code == 34175`（顶层或 data 层） | `AccountChoiceRequired`（**空列表也判多账号**） |
| 2 | `info_list`/`user_list`/`userList`/`lists`/`list` 有含 userid 的条目 | `AccountChoiceRequired` |
| 3 | 成功证据：token/userid 非空 或 `status∈{1,4}` 或 `code==200` 或二维码句柄证据 | `Success` |
| 4 | `error_code != 0` | `Failed(errorCode, convergeMessage(...))` |
| 5 | 解析失败 / 无证据无码 | `Failed(null, "登录失败，请重试")` |

仅 `503 + local_server_busy` 与连接类 `IOException` 归 `LocalFailure`。成功判据融合 lite `_isBizOk` 与 Rust 特殊状态（qr `status==4`、qr_create `code==200`）。

**文案收敛**：`Failed.message` 经 `safePlaybackErrorMessage` + 登录兜底替换，绝不外泄 URL / token / 上游报文。实现文件**零 `import android.util.Log`**（无日志调用）。

### 3.3 S3 鉴权注入 + 账号仓库

**`data/net/AuthHeaderProvider.kt`**（`@Singleton`）—— 内存鉴权头缓存（同步 `currentHeader()` / `dfid()`）。
**为什么是内存缓存**：OkHttp 拦截器在 **IO 线程同步执行**，不得在此做挂起磁盘读（阻塞 + 违反主线程纪律）；由 `AccountRepository` 在登录/启动时刷新。
dfid 走普通 prefs（文件 `kugou_auth`，键 `kugou_dfid`，与 lite 逐字一致）。

**`data/net/AuthorizationInterceptor.kt`**（F-NET-003）—— 逐条对位 lite：
- `/images` 特判（子串匹配，与 lite `contains` 一致）→ 移除 Authorization、不注入 dfid；
- 已登录 → `Authorization = token=<t>;userid=<u>[;vip_token=<v>]` + `x-apicache-bypass: 1` + `Cache-Control: no-cache`；
- 未登录 → `removeHeader("Authorization")`；
- dfid → **query** 参数（先 `removeAllQueryParameters("dfid")` 再加，防重复）。

**`data/account/AccountRepository.kt`**（`@Singleton`）
- `authState: StateFlow<AuthState>`（`LoggedOut` / `LoggedIn(userid, nickname)` / `Refreshing`）；
- 登录编排：`loginByCellphone` / `loginByCaptcha` / `beginQrLogin` / `pollQrLogin` / `beginWxLogin` / `pollWxLogin` / `completeWxLogin` / `chooseAccount`；
- `refresh()` / `logout()` / `restoreSession()` / `ensureDeviceRegistered()`；
- **副作用顺序（登录成功）**：`tokenStore.save → tokenStore.setCurrentUserid → headerProvider.update → authState=LoggedIn`；逆序清理：`clear(uid) → setCurrentUserid(null) → headerProvider.update(null) → LoggedOut`；
- 全部会话变更经 **`Mutex`** 串行化（防并发竞态）；
- `refresh()` **失败 → 清凭证登出**（失败不静默、不保留失效凭证）。

**dfid 策略**：lite 每次冷启动注册，native 改为 **prefs 有则跳过**（Rust `/register/dev` 幂等返回同一值，行为等价的优化）；**本地生成 dfid：有意不实现** —— lite 无本地生成逻辑，臆造并持久化会与 `device_info.json` 不一致（风控风险），Rust 每请求有 `random_string(24)` 兜底（`login.rs:158-166`）。

**`di/NetworkModule.kt` / `di/KugouServerModule.kt`**（修改）：`NetworkModule` 提供**唯一非限定符** `OkHttpClient`（含 `AuthorizationInterceptor`，超时与既有 `DEFAULT_CLIENT` 逐字一致）；`KugouServerModule` 增加 `provideDeviceRegistrar`（GET `/register/dev` 解析 `data.dfid`）并让 `provideKugouApi` 改用 DI client。

### 3.4 S4a DI 闭环

**`di/AccountModule.kt`**（新增）：`provideTokenStore` + `provideKugouAuthApi`（`OkHttpKugouAuthApi(ManagerKugouServerEndpoint(manager), client)`，**显式传入 DI 的共享 client**，不用类的 `DEFAULT_CLIENT`，避免登录请求绕过统一鉴权面）。
KDoc 固化约定：`OkHttpClient` 唯一由 `NetworkModule` 提供，本模块不重复提供。

**Hilt 验证**：`:app:compileDebugKotlin`（触发 `hiltJavaCompileDebug`）退出码 0，无 MissingBinding / Duplicate binding。

---

## 4. 安全设计（本阶段的核心）

| 项 | 措施 | 测试证据 |
|---|---|---|
| 凭据静态保护 | `EncryptedSharedPreferences`（AES256_GCM，Keystore 托管），两张 prefs 分立（敏感/非敏感） | `保存后 shared_prefs 下所有 xml 都不含 token 明文` |
| 凭据日志保护 | token/vipToken **零**日志（实现零 `Log` 调用或仅含 userid）；`KugouCredentials`/`LoginData`/`LoginAccount` 的 `toString()` 全部显式脱敏 | `toString 不含 token 与 vipToken 明文`、`全流程无日志输出token`（ShadowLog 断言） |
| 凭据不进 URL | token 只走 **header**，dfid 走 query（lite 既有决定） | `token不泄露到query参数` |
| 头注入安全 | header 值白名单校验（非空、0x20-0x7E、不含 `;`）—— 防污染 Rust `cookieToJson` 与 CRLF 头注入；dfid 空白拒绝 | `凭证含非法分隔符_拒绝注入Authorization`、`凭证含控制字符_拒绝注入Authorization` |
| 文案不外泄 | `Failed.message` 经 `safePlaybackErrorMessage` 收敛 | 全部 Failed 用例经 `assertSafeFailureMessage` 断言不含 mock host/URL/token |
| 会话串号 | 已认证请求强制 `x-apicache-bypass: 1`（对位 lite apicache key 不含 token 的坑） | `AuthorizationInterceptorTest` 已登录用例 |
| 外部输入校验 | body 解析 try-catch；账号条目空 userid 过滤；注册响应 JSON 防 `JsonNull`/非对象 | `空 userid 条目必须被过滤` |
| 硬编码凭据 | 源码无任何凭据字面量（MasterKey 别名走库常量） | 代码审查 + 无 `Log` |

---

## 5. 与 lite 的差异登记

| # | 差异 | 理由 |
|---|---|---|
| 1 | 不扩展 T-P1-05 冻结的 `KugouApi`，改用独立 `KugouAuthApi` | 避免契约污染；并行开发无文件冲突 |
| 2 | 用 `EncryptedSharedPreferences` 而非 `flutter_secure_storage` | 平台等价（均 Keystore）；依赖已在工程内 |
| 3 | **不做明文→加密迁移**（lite `:557-576`） | native 全新安装无历史明文数据；已由 data-migration-design §3.2 决定「令牌不跨应用迁移」 |
| 4 | `save` 不自动设置 `current_userid`（lite `setLoginCookies` 会） | 接口刻意分离两职责，调用方（`AccountRepository`）按序编排 |
| 5 | dfid 改为「prefs 有则跳过注册」（lite 每次启动都调） | Rust 幂等返回同一值，行为等价优化 |
| 6 | **不本地生成 dfid** | lite 无此逻辑；臆造会与 `device_info.json` 不一致（风控风险） |
| 7 | 未实现对位 lite 的 `noCache` 分支（`kugou_api_client.dart:282-297`） | native 无调用方，不预造 |
| 8 | `fetchUserDetail` 只抽 `userid`，不做昵称回填 | 展示字段属 UI 层 |
| 9 | `sendCaptcha` 合并 lite 两处重复定义 | 同端点 |
| 10 | `qrKey` 保留（任务书原假设无此接口，核对后确认 lite 确有 `/login/qr/key`） | `AccountRepository.beginQrLogin` 当前用客户端时间戳 key；真机若拒绝非签发 key，改为 `qrKey()` 两步（改动仅一处） |
| 11 | `LoginAccount` 增补 `token`/`vipToken` 字段 | 多账号选择需要直接用该账号凭证完成登录 |

---

## 6. 测试与验证

### 6.1 测试（新增 74 条）

| 文件 | 条数 | 覆盖 |
|---|---|---|
| `data/secure/EncryptedSharedPreferencesTokenStoreTest.kt` | 14 | round-trip、按 userid 隔离、currentUserid、clear、密文损坏容错、**无明文残留**、toString 脱敏、覆盖写 |
| `data/secure/FakeAndroidKeyStoreProvider.kt` | 测试基建 | 内存版「AndroidKeyStore」JCA Provider（见 §7 偏离 R-1） |
| `data/net/OkHttpKugouAuthApiTest.kt` | 34 | 10 方法正反例、query 参数断言、34175 多账号、取消传播、LocalFailure、脱敏、文案收敛 |
| `data/net/AuthorizationInterceptorTest.kt` | 13 | /images 特判、Authorization 三段拼接、apicache 绕过、dfid 去重、token 不进 query、头值白名单 |
| `data/account/AccountRepositoryTest.kt` | 27 | 登录编排全流程、多账号、扫码/微信、refresh 成功与失败、restoreSession、并发串行、无日志泄露 |

### 6.2 门禁（实测）

| 命令 | 退出码 | 结果 |
|---|---|---|
| `:app:compileDebugKotlin`（含 `hiltJavaCompileDebug`） | 0 | Hilt 图通过，无重复/缺失绑定 |
| `:app:testDebugUnitTest --tests "com.gracemusic.*"` | 0 | **962 tests / 0 failures / 0 errors / 0 skipped**（874 → **962**，+88） |
| `:app:lintDebug` | 0 | 见 §7 R-2（本阶段引入的 UseKtx 已修复） |
| `:app:assembleDebug` | 0 | 产物已出 |
| `:app:assembleDebugAndroidTest` | 0 | 产物已出 |
| `./gradlew projects` | 0 | 正常 |

---

## 7. 偏离与风险

### 7.1 派发期实测偏离

- **R-1 Robolectric 4.17 不支持 `AndroidKeyStore`**：`KeyStore.getInstance("AndroidKeyStore")` 抛 `KeyStoreException`（实测证实），使真实 `EncryptedSharedPreferences` 链路无法在 JVM 单测跑通。解法：新增**测试专用**内存版「AndroidKeyStore」JCA Provider（`FakeAndroidKeyStoreProvider.kt`，JVM 原生 AES + 内存 alias 表），**生产零改动、零新依赖**。
  - **这是唯一可行路径**（Robolectric 的 android-all 无法注册 Keystore provider，其 SPI 依赖 native）。待用户确认是否接受为长期方案（替代路径：升级 Robolectric 或改 instrumented 测试）。
- **R-2 本阶段引入 4 条 `UseKtx` lint 告警**（`AuthHeaderProvider.kt` / `TokenStore.kt` 的 `prefs.edit()` 未用 core-ktx）：已在验收环节打回并改用 `prefs.edit { }` 修复，lint 可见 Warning 回到既有 3 条。**这是 OMO 验收环节捕获的问题，非遗留**。

### 7.2 未完成项（如实登记，不得宣称已可用）

| 项 | 归属 |
|---|---|
| **登录 UI（LoginPage 三 tab / 我的页登录态 / 播放需登录弹窗）** | **T-P4-11 + F-STAT-007/008（P4）** |
| **`RecoveryOrchestrator` 的登录态判定**（`authenticationRequired` 仍恒 false） | 下一环；需产品确认「登录过期」是否要触发跳登录 |
| **音质降级链 VIP 通道**（20028 / 20018） | T-P1-05 延伸；需真机验证 |
| `/login`、`/login/device`、`/login/device/kick`（密码登录、设备列表、踢下线） | T-P4-11 |
| `AccountRepository` **尚无生产调用方** | UI 层接入时注入 |
| **真机三种登录方式验证** | 用户实测 |

### 7.3 风险

| ID | 描述 | 严重度 | 归属 |
|---|---|---|---|
| R6-01 | 生产 `AccountRepository` 无调用方（死代码风险，但受单测覆盖） | 🟢 | UI 接入 |
| R6-02 | 真机登录全未验证（扫码/手机/微信 + 多账号 + 切号 + 注销） | 🔴 | 用户实测 |
| R6-03 | QR key 用客户端时间戳，若上游拒绝非签发 key 需改 `qrKey()` 两步 | 🟡 | 真机联调 |
| R6-04 | 微信上游 `wx_check` 的字段命名未枚举（按多键兜底），真机需校准 | 🟡 | 真机联调 |
| R6-05 | `AccountChoiceRequired(emptyList())` 分支需 UI 处理 | 🟢 | UI |
| R6-06 | Keystore 损坏路径未覆盖（fake keystore 无法模拟硬件故障），实现按容错返回 null | 🟢 | 后续 |
| R6-07 | FakeAndroidKeyStoreProvider 是否作为长期方案待定（R-1） | 🟡 | 人类决策 |

---

## 8. 需人类介入的决策

1. **R-1 / R6-07**：是否接受「测试源码内实现内存 Keystore」作为长期方案？
2. **QR key 来源**（R6-03）：保持客户端时间戳，还是改为服务端签发 `qrKey()` 两步？建议真机首次联调后定。
3. **登录态接入播放域**：是否把 `RecoveryOrchestrator` 的 `authenticationRequired` 改为读真实登录态（会改变错误恢复行为）？还是维持「仅用 media3 鉴权码」的既有登记偏离？
4. **下一阶段优先级**：P1 剩余（T-P1-07 交叉淡化 / T-P1-09 睡眠定时执行）vs 登录 UI（T-P4-11）？

---

## 9. 真机验证清单（登录专项，补充 phase-5 清单）

| # | 步骤 | 预期 |
|---|---|---|
| L1 | 登录页扫码（酷狗 App 扫 native 二维码） | 轮询确认后登录成功；`authState=LoggedIn` |
| L2 | 手机号 + 验证码登录 | 成功；再次登录同一账号 → 覆盖凭证 |
| L3 | 微信扫码 → `openplat` 换 token | 成功（⚠️ 边界属已知未知项 V-02） |
| L4 | 登录态下请求 `/user/detail` | 返回正确昵称/头像（无串号） |
| L5 | **切账号**（登录第二个账号） | 新账号数据正确，不串旧账号；`x-apicache-bypass` 生效 |
| L6 | 注销 | token 清除、`authState=LoggedOut`、再次请求需登录态接口失败 |
| L7 | 登录后杀进程重启 | `restoreSession` 恢复登录态；**不需重新登录** |
| L8 | `adb shell run-as <pkg> cat shared_prefs/gracemusic_secure_credentials.xml` | **不含 token 明文** |
| L9 | 登录前后各播放一首 VIP/付费曲 | 对比可得音质档（验证 VIP 通道是否仍被拒） |
| L10 | 登录态过期（改密码/踢下线） | 走 `refresh` 失败 → 清凭证登出，不静默失败 |
