# 里程碑工作记录 · M2 播放核心

| 项目 | 内容 |
|---|---|
| 日期 | 2026-10-23 |
| 范围 | M2 播放核心（PRD §5.4 P-01~P-08） |
| 环境 | Windows 11 · Flutter 3.47.7 / Dart 3.13.5 · Node 22（dev proxy）· 无 Android 设备/adb |
| 分支 | `feat/m2-play-core`（从 `feat/m0-m1-skeleton` 切出） |

---

## 一、本次完成内容

### 架构决策

| 决策 | 理由 |
|---|---|
| 播放内核统一 `media_kit` 1.2.6 | 自带 Web 后端（HTMLVideoElement）+ 原生 libmpv，一套 API 双平台；放弃自写引擎/条件导入 |
| `player_engine.dart` 抽象层 | 单测注入假内核（FakeEngine），`PlayerService` 不直接依赖 media_kit |
| `PlayerService` 不 import `audio_service` | 走 `MediaSessionBridge` 抽象；移动端注入 `AudioServiceBridge`，Web/失败降级 `NoopMediaBridge` |
| 看门狗随播放懒启动 | 避免空闲空转 + widget test 残留周期 Timer（flutter_test invariant 会拦截 pending Timer） |
| Web 端音频走 `/audio` 反代 | 浏览器禁止给 `<video>` 设 UA/Referer（「禁止头」），B 站 CDN 缺一即 403 |

### 代码落地（lib/）

- **领域**：`core/domain/playback.dart`（播放会话/音质/模式枚举）、`records.dart`、`album.dart`（Chapter.copyWith）
- **API**：`core/api/play_url_service.dart`（DASH 取址 fnval=16，64k/132k/192k，**地址只存内存不落库**）、`core/api/album_source.dart`（章节来源抽象：多 P + 合集/系列；`pickSample()` 搜真实多 P 专辑，逐候选实取验证「章节 ≥2」，兜底 bvid `BV1xCJv6bEHx`）
- **播放核心** `core/services/player/`：
  - `player_engine.dart`（抽象）+ `media_kit_engine.dart`（实现，Web 端经 `_viaProxy()` 改写音频地址）
  - `player_service.dart`：专辑 → 章节 → 取址 → 播放 → 落进度全编排；分 P 连播、三种播放模式、上一章习惯（<15s 重播本章）、地址失效自愈（重试预算 3 次 + 进度地板）、断流看门狗（>40s 停滞重连）、15s 周期写盘 + 暂停/切章/退出立即写盘、睡眠定时（分钟 + 本章结束）
  - `audio_focus.dart`（五事件语义）/ `media_bridge.dart`（抽象 + Noop）/ `audio_service_bridge.dart` / `progress_store.dart`
- **DI/装配**：`di.dart`（bootstrap 注入全家桶，`warmupInBackground` 附带 `restoreLastSession()` 不自动发声）、`app.dart`（补 `Provider<AlbumSource>` / `Provider<PlayUrlService>`——修复浏览器实测发现的 Provider 未注册崩溃）、`main.dart`（移动端 `AudioService.init`，失败降级 Noop）
- **UI**：`player_page.dart`（封面/进度条 positionTick 独立节流/控制区/倍速 0.5~3.0x/定时 PRD 全档 5/10/15/30/45/60+本章结束/音质/章节抽屉/模式/加入书架/debug P-05 演练菜单）、`mini_player.dart` 接真实状态、`album_detail_page.dart` 重写、`discover_page.dart` 加 M2 样本卡
- **Android**：`MainActivity.kt`（继承 `AudioServiceActivity` + `kele/audio_focus` 焦点通道 + AUDIO_BECOMING_NOISY 拔耳机暂停）、`AndroidManifest.xml`（WAKE_LOCK/前台服务 mediaPlayback/MediaButtonReceiver）、`gradle.properties` 加 `kotlin.incremental=false`（Windows Kotlin 增量缓存 close 报错绕过）
- **Web 反代**：`tool/dev_proxy.mjs` 新增 `/audio?u=&ref=&ua=` 流式反代（node:http(s).request + Range 透传）

### 测试

- `test/player_service_test.dart` 10 用例（假内核注入）：P-03 冷启动恢复 / P-04 跨章定位 / P-05 自愈续播 / P-08 倍速音质模式持久化 / 分 P 连播 / 列表循环 / 上一章习惯 / 音质切换 / 睡眠定时 / 书架联动
- `test/widget_test.dart`（M1 冒烟）适配：分类 chips 先滚入视口；bootstrap 后 `addTearDown(services.player.dispose)`

---

## 二、M2 准出条件逐条核对（PRD §5.4 P-01~P-08）

| # | 条目 | 结果 | 证据 |
|---|---|---|---|
| P-01 | 后台播放：切后台/锁屏不断音 | 🚧 已实现待真机 | 前台服务 + WAKE_LOCK + `androidStopForegroundOnPause:false` 已接；**本机无设备/adb 无法实测** |
| P-02 | 锁屏通知展示与控制 | 🚧 已实现待真机 | AudioServiceBridge 推送播放态/元数据；**待真机** |
| P-03 | 杀进程重启回到原进度（≤5s） | ✅ 浏览器实测 | reload 后 MiniPlayer/播放页恢复同章节；点播放后代理日志显示 Range 从 1.2MB 处（≈03:20 位置）续拉；截图 `m2-03/11` |
| P-04 | 跨章续播：重进专辑定位最后章节 | ✅ 浏览器实测 | reload 后恢复第 04 章；章节抽屉当前章高亮；切第 08 章新 cid 取址自动续播；截图 `m2-09/10` |
| P-05 | 地址失效自愈 | ✅ 浏览器实测 | 演练菜单作废地址 → 代理日志 `ECONNREFUSED` → 自动重取 playurl → 原进度续播无中断；截图 `m2-04/05` |
| P-06 | 蓝牙耳机按键控制 | 🚧 已实现待真机 | MediaButtonReceiver + audio_service 媒体按键；**待真机** |
| P-07 | 导航语音打断压低/暂停恢复 | 🚧 已实现待真机 | `kele/audio_focus` 五事件（gained/interrupted/ducked/lost/noisy）移植自 abts；**待真机** |
| P-08 | 定时到点停止；倍速重启保留 | ✅ 浏览器实测 | 倍速 1.25x reload 后保留；定时选项对齐 PRD 全档 + 本章结束生效；单测覆盖定时到点暂停；截图 `m2-06/07/08` |

**判定**：P-03/P-04/P-05/P-08 浏览器实测通过；P-01/P-02/P-06/P-07 代码就绪、待真机验收。**按无设备环境的降级口径，M2 核心链路成立；真机四项不阻塞 M3 开工，但里程碑关闭前必须补测。**

---

## 三、质量关

| 检查 | 结果 |
|---|---|
| `flutter analyze` | **0 issues** |
| `flutter test` | **11/11 全绿**（M2 单测 10 + M1 冒烟 1） |
| `flutter build web`（release） | 成功 |
| `flutter build web --profile` | 成功（浏览器实测用，演练菜单需非 release） |
| `flutter build apk --debug` | 成功（`app-debug.apk` 已产出；需 `kotlin.incremental=false`） |
| 浏览器实跑 | playwright-cli，视口 430×932，10 张截图见 `docs/shortscreen/m2-*.png` |

### 浏览器实测路径（可复现）

```
发现页 →「打开样本专辑」→ 真实多 P 专辑（102 章）→ 点章节 04 播放
→ P-05 演练菜单作废地址 → 自动重取续播 → 倍速 1.25x → reload
→ MiniPlayer 恢复会话 → 点播放从原进度起播（Range 1.2MB）
→ 定时「本章结束」→ 章节抽屉切第 08 章 → 加入书架
```

---

## 四、踩坑记录

| 坑 | 处置 |
|---|---|
| 浏览器 Provider 未注册（`context.read<AlbumSource>()` 崩溃） | `app.dart` 补 `Provider<AlbumSource/PlayUrlService>` |
| `flutter_test` 报「Timer still pending」 | 看门狗改随播放懒启动（`_ensureWatchdog`），暂停/dispose 即取消 |
| M1 冒烟测试找不到「相声曲艺」 | M2 样本卡把 chips 挤出首屏，测试先 `scrollTo` |
| 搜索结果 `videos` 字段虚标（标称 2P 实际 1 页） | `pickSample` 逐候选实取验证「章节 ≥2」，全失败退兜底 |
| release 构建看不到 P-05 演练菜单（`kDebugMode=false`） | 改 `!kReleaseMode`，浏览器实测用 profile 构建 |
| `goto #/discover` 同文档导航不重新加载 JS | 每次改代码重建后必须 `reload` 而非 `goto` hash 路由 |
| Windows Kotlin 增量缓存 close 报错（audio_session 等插件模块） | `gradle.properties` 加 `kotlin.incremental=false`；杀残留 kotlin daemon |
| 8088 端口被 M1 旧代理占用 | `Get-NetTCPConnection -LocalPort 8088` 找 PID 杀掉 |
| CanvasKit 无 DOM 语义 | playwright-cli 坐标点击（mousemove/mousedown/mouseup） |
| 加入书架 SnackBar 长时间不消失挡住底部导航 | 观察到但**未修复**（见遗留项） |

---

## 五、遗留项（移交后续）

| 项 | 说明 |
|---|---|
| P-01/P-02/P-06/P-07 真机实测 | 需 Android 设备：后台/锁屏/线控/音频焦点四项；**M7 验收前必须补** |
| S3 长周期复测（M0 遗留） | `dart run tool/spike/m0_probe.dart --check` 1h/2h/4h/8h |
| SnackBar 挡底部导航 | 浏览器实测观察到「已加入书架」SnackBar 长时间不消失（疑似与 profile 构建的动画/计时有关），M3 顺手排查 |
| P-05 演练菜单 | `!kReleaseMode` 可见；M7 打 release 包前确认不出现 |
| M2 样本卡去留 | M3 发现页内容源接好后由真实分类流取代 |

## 六、命令与产物

```powershell
flutter analyze
flutter test
flutter build web --profile --no-wasm-dry-run   # 浏览器实测
flutter build apk --debug                        # 需 kotlin.incremental=false
node tool/dev_proxy.mjs                          # http://localhost:8088
```

| 产物 | 路径 |
|---|---|
| M2 单测 | `test/player_service_test.dart` |
| 验收截图 | `docs/shortscreen/m2-01…m2-10*.png`（10 张） |
| APK | `build/app/outputs/flutter-apk/app-debug.apk` |
