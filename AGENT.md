# AGENT.md — 开发阶段指引

> 本文件是 AI/开发代理在本仓库工作时的上下文入口。开始任何开发任务前，先读本文件，再按需读 `docs/` 下的对应文档。

## 项目概述

**kele-audio**：一款基于 B 站内容的 Flutter 安卓有声听书应用。不自建后端，通过 B 站公开 Web 接口取数。核心功能：发现页按类型浏览（有声书/相声曲艺/讲书/音乐/播客/英语听力）、书架收藏、完整播放链路（后台/锁屏/断点续播/倍速/睡眠定时）、儿童模式（儿童向 UI 主题 + 白名单内容过滤）。

产品定位：**个人/小范围使用工具**，非公开发行产品。

## 文档索引（按需阅读）

| 文档 | 内容 | 何时读 |
|---|---|---|
| `docs/PRD.md` | 产品需求全量文档：风险清单（R1~R8）、页面/功能详述（§5.4 P-01~P-08 播放硬性要求）、数据模型草案（§7.5）、验收标准（§10） | 做任何功能前必读对应章节 |
| `docs/milestones.md` | 里程碑 M0~M8：每个里程碑的准入条件、任务清单、准出条件 | 开始新里程碑时必读该里程碑章节 |
| `docs/reference-abts.md` | **abts（阿B听书）参考答案对照表**：PRD 风险 ↔ abts 实现位置、技术栈决策、移植清单、工期修订 | 写任何核心逻辑前先查这里，优先移植而非自写 |
| `docs/theme.md` | 五个 UI 主题的风格提示词与调色参考（含儿童模式选型） | 涉及任何 UI/主题工作时读 |
| `docs/shortscreen/` | 风格参考截图（theme.md 的源图） | 需要视觉参考时 |

## 技术决策（已定，勿改）

技术栈与 abts 项目对齐（实战验证过的听书场景选型）：

- **播放内核**：`media_kit`（+ `media_kit_libs_audio`）—— CDN 取流必须带 UA/Referer 头，`open(url, httpHeaders:)` 原生支持；**不用 just_audio**
- **状态管理**：`provider`；**本地存储**：`shared_preferences`（JSON，不用 SQLite）；**HTTP**：`dio`
- **后台/锁屏**：`audio_service`；**音频焦点**：自建原生 MethodChannel（参考 abts `audio_focus.dart`）
- **架构分层**：`lib/{app,features,core/{api,data,domain,services}}`（见 PRD §7.1），B 站接口全部收敛在 `core/api`，禁止散落业务代码
- **播放地址**：URL 只存内存（90 分钟有效），**永不落库**；持久化层只存 bvid/cid
- 本地仓库结构参照 abts 的 `core/network`（bili_client / wbi_signer / api_config 三件套）

## 参考项目（abts）

- 仓库：https://github.com/fengqiao57/abts.git （MIT 协议）
- 本地克隆：`C:\Users\EDY\AppData\Local\Temp\opencode\abts`（临时目录，可能被清理；失效时重新 `git clone --depth 1`）
- **使用规则**：
  1. 逻辑/数据层优先移植 abts 实现，先查 `docs/reference-abts.md` 定位文件与行号；
  2. **布局与主题自主设计**（按 `docs/theme.md`），不抄 abts 的 UI；
  3. **不抄**：友盟统计（`umeng_*`）、全部埋点、Windows 目标、内部调试打印；
  4. 关于页不展示 MIT 开源声明与对 abts 的致谢（用户已明确移除，勿恢复）。

## 开发顺序与硬性约束

1. 按 `docs/milestones.md` 顺序推进：M0 冒烟验证 → M1 骨架 → M2 播放核心 → M3 发现页 → M4 书架 → M5 我的 → M6 儿童模式 → M7 验收。**前一里程碑准出条件未过，不进入下一里程碑**。
2. M2 播放核心是关键路径；实现必须覆盖 PRD §5.4 的 P-01~P-08，准出按条实测。
3. 涉及 B 站接口时遵守既有风控方案（abts 已实现）：450ms 全局节流、-412/-352 阶梯退避、WBI key 日刷新——**不要绕过或另起一套**。
4. 儿童模式 = 主题皮肤 + 白名单内容过滤，**不做**防沉迷/家长控制/操作限制。
5. 每个功能完成后对照 PRD 对应验收标准自测；里程碑收尾更新 `docs/milestones.md` 进度表（⬜/🚧/✅/⏸/❌）。
6. Git：一分支一里程碑（`feat/m2-play-core`），准出合并主干打 tag（`m2`、`m3`…）。
7. 开发调试产生的临时截图都放在docs/shortscreen目录下

## 关键风险提醒（详见 PRD 第 2 章）

- **R1** 接口随时改版 → 接口路径/签名集中在 `core/api`，预留远端配置热修复；
- **R2** 风控 → 严禁高频无节流请求；测试时用退避，不硬刷；
- **R5** 播放地址过期 → 必须实现"403/超时自动重取地址并 seek 回原位"；
- **R3** 版权 → 仅在线播放、不二次分发，关于页免责声明必留。

## 项目 Logo

- **存放目录**：`E:\www\kele-audio\docs\images` —— 统一存放项目 logo 图片。
- 若当前已有图片尺寸无法满足应用图标、启动页、商店上架等不同使用场景的需求，可基于现有 logo 生成更多尺寸的版本，放入该目录以满足不同用途。

## 环境

- Flutter 3.38.x（Dart 3.10+）、JDK 17、Android SDK；构建：`flutter build apk --release`
- 平台范围：**仅 Android**（API 26+），iOS/Windows 不做。
