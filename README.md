# kele-audio

**基于 B 站内容的 Flutter 安卓有声听书应用**

把 B 站当作"听书库"：有声小说、评书、相声、讲书、音乐……点开即听；一键切换儿童模式，给孩子一个绘本与儿歌的世界。

> 项目当前处于**规划与早期开发阶段**，尚未发布可用版本。

## 简介

kele-audio 是一款**免登录、无广告、专注收听**的第三方听书播放器：

- 🔓 **免登录**：不登录即可浏览、收藏、收听、记录进度；
- 🎧 **专注收听**：章节连播、断点续播精确到秒、倍速播放、睡眠定时、后台播放与锁屏控制；
- 🧒 **儿童模式**：一键切换儿童向界面与白名单内容（绘本 / 儿歌 / 童话 / 睡前故事），操作方式与平时无异；
- 📚 **结构化收听**：发现页按类型浏览，书架收藏在听内容，"我的"记录收听统计。

## 技术

- **Flutter**（仅 Android，API 26+）
- 内容源：B 站公开 Web 接口（WBI 签名、DASH 音频流），**不自建后端**
- 播放内核：`media_kit` + `audio_service`

## 运行方式

环境要求：Flutter 3.38.x（Dart 3.10+）、JDK 17、Android SDK。

```bash
# 安装依赖
flutter pub get

# 连接 Android 设备/模拟器后运行
flutter run

# 以 Web（Chrome）方式运行，便于快速调试预览
flutter run -d chrome

# 构建 release APK
flutter build apk --release
```

> 注：项目平台范围仅 Android（API 26+），Web/Chrome 仅用于开发调试预览。

### Web 预览（浏览器调试）

浏览器有 CORS 限制且禁止设置 UA/Referer 等「禁止头」，无法直连 B 站接口，必须走本地反代 `tool/dev_proxy.mjs`（静态托管 `build/web` + 反代 `/api/*`、`/audio`、`/img`）。

**启动步骤：**

1. 启动反代（首次需要，之后可保持常驻）：

   ```powershell
   node tool/dev_proxy.mjs          # 默认 http://localhost:8088
   ```

   想换端口：`$env:PORT=9000; node tool/dev_proxy.mjs`

   判断是否已在运行：访问 `http://localhost:8088/__health`，返回 `ok` 即已启动，跳过此步。

2. 改过 `lib/` 代码后重新构建（反代无需重启，它按请求实时读 `build/web`）：

   ```powershell
   flutter build web --release
   ```

3. 浏览器访问 **http://localhost:8088**。

**常见问题：**

| 现象 | 原因 | 解决 |
|---|---|---|
| 「加载失败 / WBI 密钥获取失败」 | 用 `flutter run -d chrome` 启动，页面跑在 Flutter 自带端口，绕过了反代 | 改走 `http://localhost:8088`（见上方启动步骤） |
| 接口 502 / 请求失败 | 网络问题，反代转发不到 B 站 | 查看 dev_proxy 终端的 `[api] FAIL` 日志，检查本机网络 |
| 页面仍是旧内容 | `build/web` 未重新构建 | `flutter build web --release` 后刷新浏览器 |

日常预览不要用 `flutter run -d chrome`；`flutter run -d windows` 调试原生逻辑可以（原生端直连，不走反代）。

## 文档

| 文档 | 说明 |
|---|---|
| [docs/PRD.md](docs/PRD.md) | 产品需求文档（功能详述、风险清单、验收标准） |
| [docs/milestones.md](docs/milestones.md) | 开发里程碑计划（M0~M8） |
| [docs/theme.md](docs/theme.md) | UI 主题风格方案 |
| [docs/reference-abts.md](docs/reference-abts.md) | 参考项目（abts）实现对照 |
| [AGENT.md](AGENT.md) | 开发阶段指引 |

## 免责声明

本应用为第三方个人开发的播放工具，与哔哩哔哩官方无任何关联或背书。应用内所有音频、封面、文字等内容均来自第三方平台的公开链接，版权归原作者及相关权利人所有。本应用不存储、不修改、不二次分发任何内容，仅供个人学习与收听使用。

## 开源协议

开发中（拟采用 MIT）。
