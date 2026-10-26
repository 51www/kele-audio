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
  - `player_service.dart`：专辑 → 章节 → 取址 → 播放 → 落进度全编排；分 P 连播、三种播放模式、上一章习惯（>5s 重播本章）、地址失效自愈（重试预算 3 次 + 进度地板）、断流看门狗（>40s 停滞重连）、15s 周期写盘 + 暂停/切章/退出立即写盘、睡眠定时（分钟 + 本章结束）
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
| P-01 | 后台播放：切后台/锁屏不断音 | ✅ 真机实测 | OPPO PKC110 / Android 17；灭屏 60s `position 1663249→1730299`（推进 67s）、`state=PLAYING(3)` 保持、pid 存活；截图 `m2d-09-afterscreenoff.png` |
| P-02 | 锁屏通知展示与控制 | ✅ 真机实测 | 通知 `channel=com.kele.audio.channel.audio` / `category=transport` / `actions=3` / `FOREGROUND_SERVICE`；锁屏媒体卡 uia dump 确认封面/标题/进度/Stop·暂停·下一首，存 `m2d-08-lockscreen-uia.xml` |
| P-03 | 杀进程重启回到原进度（≤5s） | ✅ 浏览器实测 | reload 后 MiniPlayer/播放页恢复同章节；点播放后代理日志显示 Range 从 1.2MB 处（≈03:20 位置）续拉；截图 `m2-03/11` |
| P-04 | 跨章续播：重进专辑定位最后章节 | ✅ 浏览器实测 | reload 后恢复第 04 章；章节抽屉当前章高亮；切第 08 章新 cid 取址自动续播；截图 `m2-09/10` |
| P-05 | 地址失效自愈 | ✅ 浏览器实测 | 演练菜单作废地址 → 代理日志 `ECONNREFUSED` → 自动重取 playurl → 原进度续播无中断；截图 `m2-04/05` |
| P-06 | 蓝牙耳机按键控制 | ✅ 真机实测（媒体按键通路） | `keyevent 85` 播放↔暂停多轮正确、`87` 切章 K 801-850→851-900、`88` 按 >5s 规则回上一章；日志确认 `KEYCODE_MEDIA_PLAY_PAUSE` 路由到我方 session 并 `requestAudioFocus`。**物理耳机实按留 M7**（无硬件）；该 ROM `media dispatch` 不可用（`sh: media: inaccessible`） |
| P-07 | 导航语音打断压低/暂停恢复 | ✅ 真机实测 | 三个事件真机验证：`interrupted`（相机录像 `GAIN_TRANSIENT` 抢占 → 我方 `LOSS_TRANSIENT` 暂停 → 释放后 `onAudioFocusChange(1)` → **自动续播**）、`ducked`（语音助手 `GAIN_TRANSIENT_MAY_DUCK` → 播放不中断）、`lost`（音乐播放器永久抢占 → 暂停且不自动恢复）。`noisy` 因受保护广播无法注入 + 无耳机，由 4 个单测 + 原生 `ACTION_AUDIO_BECOMING_NOISY` receiver 代码覆盖 |
| P-08 | 定时到点停止；倍速重启保留 | ✅ 浏览器实测 | 倍速 1.25x reload 后保留；定时选项对齐 PRD 全档 + 本章结束生效；单测覆盖定时到点暂停；截图 `m2-06/07/08` |

**判定**：**P-01~P-08 全部通过（8/8），M2 准出条件达成。** P-03/04/05/08 浏览器实测，P-01/02/06/07 真机实测（清单 `.logs/m2-device-checklist.md`，截图 `docs/shortscreen/m2d-*.png`）。

### 本轮（2026-10-26）真机补测修复的缺陷

| # | 缺陷 | 处置 |
|---|---|---|
| 1 | `PlaybackState` 断言 `androidCompactActionIndices.length <= 3` 崩溃（控制台超 3 个） | 控件列表与紧凑下标改为动态计算（`audio_service_bridge.dart`） |
| 2 | release 资源收缩剔除 audio_service 图标 → Android 13+ 构建 CustomAction 抛 `IllegalArgumentException` | 新增 `android/app/src/main/res/raw/keep.xml` 保活（已验证 release arsc 含 `audio_service_stop`/`audio_service_play_arrow`） |
| 3 | **音频焦点五事件回调从未接线**：`_bindFocus`/`_restoreVolume` 全库无人赋值，打断不会暂停/恢复 | 新增 `_bindFocus()`（interrupted→暂停续播 / lost→暂停不续播 / ducked→音量 0.3 / gained→还原+续播 / noisy→暂停），`init()` 调用，`dispose()` 置空回调防单例泄漏 |
| 4 | 通知栏/锁屏进度按 1.0 倍速外推 | `MediaSnapshot` 新增 `speed`，`_pushBridge` 传真实倍速 |
| 5 | 文档笔误：上一章规则写 "<15s"，代码与单测实为 ">5s"（PRD 未规定） | 已订正 `milestone-2.md` / `m2-device-checklist.md` |

---

## 三、质量关

| 检查 | 结果 |
|---|---|
| `flutter analyze` | **0 issues** |
| `flutter test` | **18/18 全绿**（M2 单测 10 + M1 冒烟 1 + 桥接回归 3 + P-07 焦点 4） |
| `flutter build web`（release） | 成功 |
| `flutter build web --profile` | 成功（浏览器实测用，演练菜单需非 release） |
| `flutter build apk --debug` | 成功（`app-debug.apk` 已产出；需 `kotlin.incremental=false`） |
| `flutter build apk --release` | 成功（`app-release.apk` 72.3MB，2026-10-26 真机验证用） |
| 浏览器实跑 | playwright-cli，视口 430×932，10 张截图见 `docs/shortscreen/m2-*.png` |
| 真机实跑 | adb + uiautomator，OPPO PKC110 / Android 17，截图/证据见 `docs/shortscreen/m2d-*`、`.logs/m2-device-checklist.md` |

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
| PowerShell `>` 重定向写 PNG/XML 会破坏二进制与编码 | 截图走 `cmd /c` 或 `adb pull`；XML 用 `adb pull` 后 `[IO.File]::ReadAllText(…, UTF8)` 解析 |
| 控制台打印中文/`content-desc` 乱码 | `[Console]::OutputEncoding = [Text.Encoding]::UTF8`；属性名写 `$_.'content-desc'` |
| 手算坐标点击常偏移（截图显示有缩放） | 改 `uiautomator dump`（Flutter 语义已开）取控件中心点，工具 `tool/device/tap.ps1` / `shot.ps1` |
| release 包 audio_service 图标被资源收缩剔除 | `res/raw/keep.xml` 保活（见缺陷 2） |
| 焦点五事件在真机上从不触发 | 原生侧事件一直在发，但 Dart 侧从未赋值回调（见缺陷 3） |
| 想靠第三方 App 触发瞬时焦点屡试不中 | 音乐播放器是永久 GAIN（走 `lost`）、ColorOS 计时器走 STREAM_ALARM 不抢焦点、录音机弹隐私协议不能代同意 → 最终用**相机录像**拿到 `GAIN_TRANSIENT` |
| `am broadcast -a android.media.AUDIO_BECOMING_NOISY` 被系统拒绝 | 受保护广播（`SecurityException`），`noisy` 改由单测 + 原生 receiver 代码覆盖 |
| 锁屏态 `screencap` 返回黑屏（ROM 限制） | 改用 `uiautomator dump` 取锁屏媒体卡控件树作证据 |
| 设备上旧包 `com.example.kele_music_client` 也用 audio_service | `dumpsys media_session` 按 `media-session/xxx` + `custom actions=[…Stop…]` + `package=com.kele.audio` 区分 |

---

## 五、遗留项（移交后续）

| 项 | 说明 |
|---|---|
| 物理耳机实按（P-06 完整路径） | 无有线/蓝牙耳机硬件，本次走 adb 媒体按键通路验证；**M7 验收时实按** |
| `noisy` 端到端（P-07） | 受保护广播无法注入 + 无耳机，已由 4 个单测 + 原生 `ACTION_AUDIO_BECOMING_NOISY` receiver 代码覆盖；**M7 有耳机后实拔复验** |
| 用户通知权限 `POST_NOTIFICATIONS` 真实授权流 | `pm install -g` 已自动授予，**真实用户首次授权弹窗路径待 M7 验收** |
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
flutter build apk --release                      # 真机验证（72.3MB）
node tool/dev_proxy.mjs                          # http://localhost:8088
```

真机辅助（adb 不在 PATH，固定 `E:\android-sdk\platform-tools\adb.exe`）：

```powershell
.\tool\device\tap.ps1 -Label 播放      # uiautomator 定位控件中心点并点击
.\tool\device\shot.ps1 -Name m2d-00    # 截图归档到 docs\shortscreen\
```

| 产物 | 路径 |
|---|---|
| M2 单测 | `test/player_service_test.dart`（14：原 10 + P-07 焦点 4） |
| 桥接回归单测 | `test/audio_service_bridge_test.dart`（3） |
| 真机补测清单 | `.logs/m2-device-checklist.md` |
| 浏览器验收截图 | `docs/shortscreen/m2-01…m2-10*.png`（10 张） |
| 真机验收截图/证据 | `docs/shortscreen/m2d-*.png` + `m2d-08-lockscreen-uia.xml` |
| APK | `build/app/outputs/flutter-apk/app-debug.apk`、`app-release.apk` |
| release 图标保活 | `android/app/src/main/res/raw/keep.xml` |
| 真机操作工具 | `tool/device/tap.ps1`、`tool/device/shot.ps1` |
