# M2 真机补测清单（P-01 / P-02 / P-06 / P-07）—— 2026-10-26 已完成

> 前置：P-03/P-04/P-05/P-08 已浏览器实测通过（见 `.logs/milestone-2.md`）。
> 本清单补 2026-10-23 因无设备挂起的四项。adb = `E:\android-sdk\platform-tools\adb.exe`（不在 PATH）。
> **实测设备**：OPPO PKC110 / Android 17（API 37），1080×2376，包名 `com.kele.audio`，release APK 72.3MB。
> 截图工具：`tool/device/shot.ps1`（注意：PowerShell `>` 会破坏 PNG，必须 `cmd /c` 或 `adb pull`）。

## 0. 环境准备 ✅

```powershell
$env:PATH = "E:\android-sdk\platform-tools;" + $env:PATH
adb devices -l                      # 已授权 USB 调试
flutter build apk --release         # 成功 72.3MB
adb install -r -g build\app\outputs\flutter-apk\app-release.apk   # -g 自动授权
adb shell am start -n com.kele.audio/.MainActivity
```

播放链路：发现页 →「打开样本专辑」→ 专辑详情 →「播放全部」（实际样本为有声书《我本无意成仙》58 章）。

## 1. P-01 后台播放 —— ✅ 通过

| # | 动作 | 期望 | 结果 |
|---|---|---|---|
| 1.1 | 播放中按 HOME（`input keyevent 3`） | 声音不断 | ✅ 前台服务存活，session `active=true` |
| 1.2 | `input keyevent 26` 灭屏锁屏 | 声音不断 | ✅ 灭屏 60s：`state=PLAYING(3)` 保持，`position 1663249→1730299`（推进 **67s**），pid 15588 存活 |
| 1.3 | 亮屏 `keyevent 26`+`82` 回到 App | 同章节同进度 | ✅ 截图 `m2d-09-afterscreenoff.png` |
| 1.4 | 中断恢复（见 §4） | 打断结束自动续播 | ✅ 见 4.1/4.2 |

## 2. P-02 锁屏 / 通知栏展示与控制 —— ✅ 通过

| # | 动作 | 期望 | 结果 |
|---|---|---|---|
| 2.1 | 播放中下拉通知栏 | 媒体通知：封面/标题/播放暂停/上下章 | ✅ `NotificationRecord`：`channel=com.kele.audio.channel.audio`、`category=transport`、`actions=3`、`flags=NO_CLEAR\|FOREGROUND_SERVICE`、`importance=2`；截图 `m2d-07/10-notification.png` |
| 2.2 | 通知栏点「暂停」 | App 暂停，通知变「播放」 | ✅ session `state=PAUSED(2)`（11:28:35 日志） |
| 2.3 | 通知栏/按键点「下一章」 | 切章续播 | ✅ 章节 `K 801-850 → K 851-900` |
| 2.4 | 锁屏界面 | 媒体控件与封面标题 | ✅ `uiautomator dump` 确认标题/章节/进度 + Stop·暂停·下一首，证据存 `docs/shortscreen/m2d-08-lockscreen-uia.xml`（锁屏态 `screencap` 返回黑屏为 ROM 限制，改用 uia dump） |

> 附：`pm install -g` 已自动授予 `POST_NOTIFICATIONS`，真实用户授权弹窗路径留 M7 验收。

## 3. P-06 耳机 / 蓝牙线控 —— ✅ 通过（媒体按键通路）

| # | 动作 | 期望 | 结果 |
|---|---|---|---|
| 3.1 | `input keyevent 85`（MEDIA_PLAY_PAUSE） | 播放↔暂停切换 | ✅ 多轮 `PLAYING→PAUSED→PLAYING` 均正确；日志确认 `KEYCODE_MEDIA_PLAY_PAUSE` 路由到 `com.kele.audio/media-session/226` 并触发 `requestAudioFocus()` |
| 3.2 | `input keyevent 87`（MEDIA_NEXT） | 下一章 | ✅ `K 801-850 → K 851-900` |
| 3.3 | `input keyevent 88`（MEDIA_PREVIOUS） | 上一章（播放 >5s 则重播本章，否则回上一章） | ✅ `pos=0 <5s` 时回上一章 `K 851-900 → K 801-850`；>5s 重播本章另由单测覆盖 |
| 3.4 | `media dispatch play/pause/…` | 同上（MediaSession 路径） | ❌ **该 ROM 不可用**：`/system/bin/sh: media: inaccessible or not found`；等价能力已由 3.1~3.3 的 keyevent 通路覆盖 |
| 3.5 | 真机有线/蓝牙耳机实按 | 同上 | ⏸ **跳过**：无耳机硬件；留 M7 验收 |

## 4. P-07 音频焦点 —— ✅ 通过（3/4 事件真机验证）

| # | 动作 | 期望 | 结果 |
|---|---|---|---|
| 4.1 | 播放中打开**相机录像**（抢麦克风 → TRANSIENT 焦点丢失） | 播放暂停 | ✅ `com.oplus.camera` 请求 `GAIN_TRANSIENT`；我方条目 `loss: LOSS_TRANSIENT -- notified: true` → session `state=PAUSED(2)` 停在 `position=1626750` |
| 4.2 | 结束录像，回到前台 | 自动续播（`gained`） | ✅ 焦点归还日志 `AudioManager(15588): dispatching onAudioFocusChange(1)` → session `state=PLAYING(3)`，`position 1626750→1635000` 持续推进 |
| 4.3 | 播放中触发提示音/助手（CAN_DUCK） | 音量压低不断播 | ✅ 语音助手 `com.heytap.speechassist` 请求 `GAIN_TRANSIENT_MAY_DUCK`，我方 `loss: LOSS_TRANSIENT_CAN_DUCK` → **播放未中断**（`state=PLAYING` position 持续推进）；退出后焦点归还 |
| 4.4 | `am broadcast -a android.media.AUDIO_BECOMING_NOISY` | 立即暂停（`noisy`） | ⏸ **不可注入**：受保护广播，shell 报 `SecurityException: Permission Denial`；且无耳机可物理拔插 → 改由 **4 个单测**（interrupted/lost/ducked/noisy）+ 原生 `ACTION_AUDIO_BECOMING_NOISY` receiver 代码覆盖 |
| 4.5 | 另一播放器抢占（系统播放器播 mp3） | 我方暂停且不自动恢复（`lost`） | ✅ `com.coloros.video` 请求 `GAIN`（永久）→ 我方收到 `onAudioFocusChange(-1)` → `state=PAUSED(2)` 停在 `position=1118250`，抢占方结束后**未自动恢复**（符合语义表：`lost` 交用户手动继续） |

**试过但无效的手段**（供后续复现参考）：ColorOS 计时器响铃走 `STREAM_ALARM` 直接发声不抢焦点；录音机弹第三方隐私协议（不能代用户同意）；`cmd audio` 无焦点模拟命令；`com.heytap.speechassist` 走 `ASSIST` 时不抢焦点（需 `keyevent 231` VOICE_ASSIST 才触发）。

> 判定：P-07 核心（4.1 中断→4.2 恢复）真机通过；4.3 ducked 真机通过；4.4 noisy 单测覆盖；4.5 lost 真机通过。

## 5. 收尾 —— ✅ 完成

- [x] 四项结论写回 `docs/milestones.md` 进度表与 `.logs/milestone-2.md` 第二节
- [x] 截图归档 `docs/shortscreen/m2d-*.png`（含 `m2d-08-lockscreen-uia.xml` 证据）
- [x] 质量关：`flutter analyze` 0 issue、`flutter test` 18/18、`flutter build apk --release` 成功
- [x] `git merge` 回主干 + 打 tag `m2`

**最终判定：M2 准出 P-01~P-08 全部通过（8/8）。**
遗留移交 M7：物理耳机实按（P-06 完整路径）、`noisy` 物理拔插复验、真实用户 `POST_NOTIFICATIONS` 授权弹窗路径。
