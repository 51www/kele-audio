# 里程碑工作记录 · M0 + M1

| 项目 | 内容 |
|---|---|
| 日期 | 2026-10-23 |
| 范围 | M0 技术验证（Spike）+ M1 工程骨架 |
| 环境 | Windows 11 · Flutter 3.47.7 / Dart 3.13.5 · Node 22（dev proxy） |
| 分支 | `feat/m0-m1-skeleton`（主干先落文档基线，再切分支提交代码） |

---

## 一、本次完成内容

### M0 技术验证（降级为移植冒烟）

按 `docs/reference-abts.md` §4 口径：`core/api` 整体移植自 abts，M0 不重新发明，
只验证"移植后的代码在本项目里仍能工作"。

- 新增 `tool/spike/m0_probe.dart`：纯 Dart CLI，**直接复用 `lib/core/api`** 的
  `BiliClient`（同一份节流/退避/WBI/请求头代码），避免冒烟与 App 两张皮；
- S1 WBI 搜索 PASS、S2 多P + DASH 音频流 PASS（接口层）、S3 有效期部分实测、
  S4 待真机。详见 `docs/spike-report.md`；
- 结果存档：`tool/spike/m0_result.json`、`tool/spike/last_play_url.json`；
- `--check` 子命令支持后续 1h/2h/4h/8h 长周期复测。

**关键改造**：`core/api` 从"直接依赖 SharedPreferences"改成**注入 `KeyValueStore` 接口**，
App 端用 `PrefsKeyValueStore`（SharedPreferences 适配器）实现，CLI 端用内存实现——
这是 `m0_probe.dart` 能在纯 Dart（无 Flutter binding）环境复用 `core/api` 的前提。

### M1 工程骨架

#### 目录结构（PRD §7.1）

```
lib/
├── core/
│   ├── api/          # B 站接口收敛地：bili_client / wbi_signer / cookie_jar /
│   │                 # api_config / key_value_store / prefs_kv_store
│   ├── domain/       # 领域模型：album / chapter / play_progress …
│   ├── data/         # 六表数据层：table / local_database / daos / dao_demo
│   └── services/     # （M2 填肉：播放服务等）
├── app/              # theme（palette/tokens/app_theme/theme_controller）/
│                     # router（十路由）/ home_shell / di / app / widgets
├── features/         # discover / shelf / profile（+5 二级页）/ player / mini_player
└── main.dart
assets/api/api_config.json   # 接口配置（R1 热修复预留）
```

#### 七项任务落地情况

| # | 任务 | 状态 | 说明 |
|---|---|---|---|
| 1 | Flutter 工程初始化 | ✅ | 包名 `com.kele.audio`、应用名「可乐听书」、minSdk 26；依赖 dio / shared_preferences(JSON) / go_router / media_kit / provider / audio_service（按 `AGENT.md` 固定清单，未引入 sqflite/riverpod） |
| 2 | 目录骨架 | ✅ | `app/ features/ core/{api,data,domain,services}` 与 PRD §7.1 一致 |
| 3 | 三 Tab 壳 + MiniPlayer | ✅ | `StatefulShellRoute.indexedStack` 三 Tab 状态保留；MiniPlayer 占位组件（M2 接真实状态） |
| 4 | 全局主题体系 | ✅ | token 化（`theme/tokens.dart`），浅/深/跟随系统；`ThemeController` 持久化；**代码零硬编码颜色**（analyze 辅助保证）；取 `docs/theme.md` 主题1（浅色暖纸书卷）+ 主题3（深色暗夜金橙），主题5 留 M6 儿童模式 |
| 5 | core/api 雏形 | ✅ | UA/Referer/Cookie 管理、450ms 节流、-412/-352 阶梯退避、WBI 日刷新、-412 统一拦截；接口配置 JSON 加载（`assets/api/api_config.json`） |
| 6 | 本地数据层 | ✅ | `shared_preferences` 存 JSON（**不用 SQLite**，按 `AGENT.md`）；六表 `LocalDatabase` + DAO 封装 + `dao_demo`（建表/读写自检） |
| 7 | 路由表 | ✅ | PRD §4.2 十路由全部建占位页（`app/router/app_router.dart`） |

#### 接口调试设施（Web 预览）

- `flutter build web --platforms=android,web` 可产出 Web 版；
- API 走同源相对前缀 `/api`，本地反代 `tool/dev_proxy.mjs`（Node 22，零依赖）：
  - 静态托管 `build/web/`；
  - `/api/*` 反代到 B 站，并把 `X-Kele-UA / Referer / Cookie` 还原成真实请求头
    （绕开浏览器 CORS 的同时不损失请求纪律）；
- Android 端仍直连（不走 proxy）。

#### 依赖清单（与 `AGENT.md` 对齐）

| 用途 | 包 | 备注 |
|---|---|---|
| 网络 | `dio` | B 站接口 |
| 本地存储 | `shared_preferences` | **JSON 存储，不用 SQLite** |
| 路由 | `go_router` | 十路由 |
| 播放 | `media_kit` + `media_kit_libs_video` | M2 用 |
| 后台播放 | `audio_service` | M2 用 |
| 状态管理 | `provider` | 轻量，够用 |

---

## 二、M1 准出条件逐条核对

| # | 准出条件 | 结果 | 证据 |
|---|---|---|---|
| 1 | 三 Tab 切换保留滚动状态 | ✅ | 截图 `m1-08-tab-scroll-retained.png`；`test/widget_test.dart` 覆盖 |
| 2 | 全局主题切换生效（浅/深色） | ✅ | 截图 `m1-01`（浅色）/ `m1-05`（深色）；reload 后仍深色（SP 持久化已验证）；测试覆盖 |
| 3 | core/api 发出带完整头的请求并返回 | ✅ | 截图 `m1-02-api-probe-result.png`（HTTP 200 + 完整请求头）；网络面板确认 `/api/x/...` 200 |
| 4 | 数据库建表成功，DAO 读写 Demo 跑通 | ✅ | 截图 `m1-03`（建表信息）/ `m1-04`（DAO Demo 通过 · 5ms） |
| 5 | 目录结构与 PRD §7.1 一致 | ✅ | 见上方目录树 |

**M0 准出**（4 项验证全过）：S1 ✅ / S2 ✅（接口层）/ S3 🚧（120min + T+14min，长周期待补）/ S4 ⏸（待真机）。
按 `docs/reference-abts.md` §4 降级口径判定：**接口地基成立，不阻塞 M2 开工**；
S3 长周期与 S4 真机项移交 M2 真机实测。

---

## 三、质量关

| 检查 | 结果 |
|---|---|
| `flutter analyze` | **0 issues** |
| `flutter test` | **全绿**（`test/widget_test.dart`：三 Tab、主题切换、DAO demo、二级页返回） |
| `flutter build web` | 成功（`--platforms=android,web`） |
| 浏览器实跑 | playwright-cli，视口 430×932，8 张截图见 `docs/shortscreen/` |

### 测试覆盖（widget_test.dart）

- 三 Tab 切换 + 状态保留；
- 主题浅↔深切换生效 + SP 持久化；
- DAO Demo（建表 → 写 → 读 → 校验）；
- 二级页 push / 返回。

### 截图清单（`docs/shortscreen/`）

| 文件 | 内容 |
|---|---|
| `m1-01-discover-light.png` | 发现页（浅色主题） |
| `m1-02-api-probe-result.png` | 接口自检 HTTP 200 + 完整请求头 |
| `m1-03-shelf-empty-and-created.png` | 书架空态 + 建表信息 |
| `m1-04-shelf-dao-demo-pass.png` | DAO Demo 通过 · 5ms |
| `m1-05-profile-dark-theme.png` | 我的页（深色主题） |
| `m1-06-about-disclaimer-mit.png` | 关于页（免责声明 + MIT 致谢 abts） |
| `m1-07-discover-dark-probe-kept.png` | 深色发现页（接口结果跨 Tab 保留） |
| `m1-08-tab-scroll-retained.png` | Tab 往返后滚动位置保留 |

---

## 四、命令与产物

### 复现命令

```powershell
# M0 冒烟
dart run tool/spike/m0_probe.dart          # S1+S2+S3
dart run tool/spike/m0_probe.dart --check  # S3 长周期复测

# 质量关
flutter analyze
flutter test
flutter build web --platforms=android,web

# Web 预览（另开一个终端）
node tool/dev_proxy.mjs    # http://localhost:8088
```

### 产物清单

| 产物 | 路径 |
|---|---|
| M0 验证脚本 | `tool/spike/m0_probe.dart` |
| M0 结果存档 | `tool/spike/m0_result.json`、`tool/spike/last_play_url.json` |
| M0 验证报告 | `docs/spike-report.md` |
| 接口配置 | `assets/api/api_config.json` |
| Web 反代 | `tool/dev_proxy.mjs` |
| M1 冒烟测试 | `test/widget_test.dart` |
| 验收截图 | `docs/shortscreen/m1-01…08*.png`（8 张） |

---

## 五、遗留项（移交 M2）

| 项 | 说明 |
|---|---|
| S2 真机播放 | 本机无 Android 设备 / adb，接口层已验，真机按 P-01~P-08 实测 |
| S3 长周期复测 | 1h/2h/4h/8h `--check`；本次仅 T+14min + deadline≈120min 证据；**不阻塞 M2**（R5 按保守 90min 设计） |
| S4 后台播放 Demo | `audio_service` 真机验证（锁屏控制、杀进程续播）归 M2 |
| MiniPlayer | M1 为占位组件，M2 接真实播放状态 |

## 六、踩坑记录

| 坑 | 处置 |
|---|---|
| `playUrl.data['data']?['dash']` 在条件表达式中 `?[]` 解析失败 | 拆行赋值再判空 |
| `StatefulShellRoute.indexedStack` 无 `id` 参数 | 用 index 区分 shell |
| MiniPlayer 文本溢出 1px | 调 padding / 固定高度 |
| Flutter CanvasKit 无 DOM 文本，Playwright 无法定位元素 | 靠坐标点击（mousemove/mousedown/mouseup） |
| `core/api` 直接依赖 SharedPreferences，CLI 无法复用 | 抽 `KeyValueStore` 接口注入 |
