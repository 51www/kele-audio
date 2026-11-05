# M9 阅读与听书 · 总体规划

> 状态：方案定稿，待开发（里程碑与进度见 `docs/reader-milestones.md`，技术设计见 `docs/reader-design.md`）
> 定稿日期：2026-11-04

## 1. 背景与目标

对应 README「待完成功能项」：

- **阅读及朗读本地书籍**：导入本地书籍文本，支持阅读与 TTS 朗读收听；
- **音频文档同步**：朗读时与文本同步高亮（本方案落地阅读侧的段落级高亮同步）。

新增需求：**导入网页链接**，抓取正文后用 TTS 朗读。

一句话目标：在 kele-audio 中新增「本地书」能力——支持导入 TXT / EPUB / 网页文章，翻页阅读，并以系统 TTS、在线 TTS（内置 Edge TTS + 自定义 HTTP TTS 服务）两种方式听书，后台听书体验与现有 B 站音频播放完全统一。

### 非目标（明确不做）

- 不做 legado 式「书源规则引擎」，不做小说目录页整本抓取（仅单篇文章）；
- 不做划词翻译、笔记、AI 摘要等阅读器增值功能；
- 不支持 MOBI/AZW3/PDF 等其他格式（foliate-js 架构上预留，后续按需开放）；
- Flutter Web 预览端阅读页做降级占位（WebView 不可用），不做完整适配；
- 平台范围维持仅 Android（API 26+）。

## 2. 市面开源项目调研结论（2026-11）

| 项目 | 技术栈 / 许可证 | 能力覆盖 | 结论 |
|---|---|---|---|
| **anx-reader（安读）** [Anxcye/anx-reader](https://github.com/Anxcye/anx-reader)（9.2k★） | Flutter / **MIT** | EPUB/MOBI/AZW3/FB2/TXT/PDF、翻页+滚动、系统 TTS（fork 版 flutter_tts）+ audio_service 后台 | ★ 主体借鉴对象：同为 Flutter 且 MIT，集成代码可直接参考/拷贝 |
| **Readest** [readest/readest](https://github.com/readest/readest)（24.5k★） | Next.js + Tauri（TS）/ AGPL-3.0 | 系统 TTS + Edge TTS 云端、锁屏控制 | 仅作架构参考：技术栈不符 + AGPL 传染，不拷代码 |
| **legado（阅读）** [gedoor/legado](https://github.com/gedoor/legado)（39k★） | Kotlin / GPL-3.0 | TXT 体验、系统 TTS、在线朗读引擎（自定义 HTTP TTS URL 模板） | 仅参考「在线朗读引擎」URL 模板协议设计，GPL 代码不拷贝 |
| Flutter 生态组件 | — | `flutter_tts`、`edgetts-dart`（Edge TTS 纯 Dart 免密钥）、`charset`/`fast_gbk`（GBK 编码识别）、`archive`（EPUB 打包） | 组件级直接复用 |

**核心结论**：不整体引入任何项目，以 anx-reader 的 WebView + foliate-js 集成为模板（MIT 合规），TTS 与网页抓取部分自行实现。

## 3. 选型决策（已与需求方确认）

| # | 决策点 | 结论 |
|---|---|---|
| D1 | 阅读渲染内核 | **foliate-js（MIT）+ `flutter_inappwebview`（官方 pub 版，不用 anx-reader 的 fork）** |
| D2 | 书籍格式 | **TXT + EPUB**；TXT 侧自动编码识别（UTF-8/GBK）+ 章节切分 |
| D3 | 网页导入范围 | **单篇文章**（公众号/新闻/博客），不做整本抓取 |
| D4 | 网页抓取通道 | **隐藏 WebView + Readability.js**（页面 JS 执行后提取，覆盖 JS 渲染页，不易被反爬拦截） |
| D5 | 网页内容存储 | **导入即存快照**，离线可读；书详情提供「重新抓取」手动更新 |
| D6 | TTS 引擎 | **三档可插拔**：系统 TTS（`flutter_tts`）/ 内置 Edge TTS（`edgetts-dart`，免密钥）/ 自定义 HTTP TTS URL 模板（协议参考 legado 在线朗读引擎） |
| D7 | 后台听书 | **复用现有 `audio_service` 体系**（锁屏/通知栏/线控/睡眠定时），与 B 站音频播放互斥 |
| D8 | 架构与存储 | 沿用项目既定栈：`provider` + `shared_preferences`（JSON）+ 现有分层，**不引入** SQLite、Riverpod 等新状态管理/存储 |

## 4. 总体架构

核心设计思想：**三类来源统一为「章节文本流」**——TXT 解码切章、网页 Readability 提取正文后，都在 Dart 侧包装成轻量 EPUB；EPUB 文件原样存储。这样 WebView 内只有一条渲染路径（foliate-js 打开 EPUB），TTS 段落提取也只有一条管线：

```mermaid
flowchart TD
    subgraph 导入层[M9.1 导入与书架]
        A1[TXT 文件<br/>编码识别+切章+转EPUB]
        A2[EPUB 文件<br/>校验后直存]
        A3[网页 URL<br/>隐藏 WebView + Readability.js<br/>正文提取→切章→转EPUB 快照]
    end
    导入层 --> B[(书籍文件落盘 books/{id}/book.epub<br/>元数据 shared_preferences JSON)]
    B --> C[M9.2 阅读页<br/>flutter_inappwebview + foliate-js<br/>分页/滚动 · 排版设置 · 目录 · 进度]
    B --> D[M9.3 TTS 听书<br/>TtsEngine 抽象]
    C -->|段落提取/高亮/进度| D
    subgraph TTS引擎[D9 三档引擎]
        D1[系统 TTS<br/>flutter_tts]
        D2[Edge TTS<br/>edgetts-dart + media_kit 播放]
        D3[自定义 HTTP TTS<br/>URL 模板]
    end
    D --> TTS引擎
    D --> E[现有 audio_service 桥<br/>后台/锁屏/线控/睡眠定时<br/>与 B 站播放互斥]
```

## 5. 新增依赖与 vendored 资产

### 5.1 pub 依赖（版本以 pub.dev 最新稳定为准，锁定后写入 pubspec.yaml 注明 M9）

| 包 | 用途 |
|---|---|
| `flutter_inappwebview` | Android WebView 容器（阅读页 + 网页抓取） |
| `flutter_tts` | Android 系统 TTS |
| `edgetts-dart`（或等价纯 Dart Edge TTS 实现，spike 时定版） | 微软 Edge 在线语音合成（免密钥） |
| `archive` | 轻量 EPUB 打包（TXT/网页正文 → EPUB） |
| `charset` + `fast_gbk` | TXT 编码检测与 GBK 解码 |

### 5.2 vendored 资产（第三方源码本地集成）

| 资产 | 目录 | 许可证 |
|---|---|---|
| foliate-js | `assets/reader/foliate-js/` | MIT |
| Mozilla Readability（单文件 Readability.js） | `assets/reader/readability/` | Apache-2.0 |

### 5.3 许可证与致谢要求

- 两个 vendored 项目均允许商用集成；**必须**在 README「致谢」表和关于页开源许可列表中登记（foliate-js、Readability.js、anx-reader 参考）；
- anx-reader 代码为 MIT，可拷贝，但**不引入其任何 fork 依赖**（flutter_inappwebview / flutter_tts / langchain 等一律用官方版本）；borrowed 逻辑在代码注释标注来源；
- legado（GPL-3.0）与 Readest（AGPL-3.0）**只参考协议/交互设计，禁止拷贝任何代码**。

## 6. 里程碑总览

按 `AGENT.md` 里程碑纪律推进：一分支一里程碑（`feat/m9-reader`，tag `m9`），前一阶段准出未过不进入下一阶段。详细任务与准出条件见 `docs/reader-milestones.md`。

| 阶段 | 内容 | 关键产出 |
|---|---|---|
| **M9.0** | 技术验证 spike（WebView 加载 foliate-js / Readability 双验证） | 真机 demo + spike 结论（ES module 加载方案定版） |
| **M9.1** | 三路导入与书架 | TXT/EPUB/URL 导入闭环、书籍落盘、书架「本地书」分组 |
| **M9.2** | 阅读页 | foliate-js 渲染、分页/滚动、排版设置、目录、进度续读 |
| **M9.3** | TTS 听书 | 三档引擎、段落管线、高亮同步、audio_service 后台集成 |
| **M9.4** | 设置与收尾 | 听书配置页、备份纳入、连通性自检、release notes、README 勾选 |

## 7. 主要风险与对策

| # | 风险 | 对策 |
|---|---|---|
| R-1 | foliate-js 为 ES module，Android WebView 从 Flutter asset 加载可能受阻 | M9.0 spike 优先消化；受阻则改用 rollup 单文件打包或 `loadData` 内嵌方案 |
| R-2 | 公众号等站点反爬 / 正文提取失败 | WebView 携带真实浏览器环境成功率高；失败重试一次后给出区分明确的错误态，并提供「WebView 内打开重试」 |
| R-3 | Edge TTS 国内网络可达性 | 设置页内置连通性自检 + 试听；自定义 HTTP TTS 模板作为兜底 |
| R-4 | `flutter_inappwebview` 增加包体（约 +3~5MB） | 仅 Android 引入；与现有 split-per-ABI 分发策略一致 |
| R-5 | TTS 与 B 站播放抢占音频焦点/播放器实例 | TTS 使用独立 media_kit Player 实例 + 启动时互斥停止对方；音频焦点沿用现有自建 MethodChannel 方案 |
| R-6 | 备份体积膨胀 | 备份只含书籍元数据与进度，不含书籍文件本身（文档明示） |
