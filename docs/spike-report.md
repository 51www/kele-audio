# M0 技术验证（Spike）报告

| 项目 | 内容 |
|---|---|
| 报告日期 | 2026-10-23 |
| 执行环境 | Windows 11 · Flutter 3.47.7 / Dart 3.13.5 · 本机无 Android 设备（adb 不可用） |
| 验证工具 | `tool/spike/m0_probe.dart`（纯 Dart CLI，直接复用 `lib/core/api`） |
| 结果存档 | `tool/spike/m0_result.json`、`tool/spike/last_play_url.json` |
| 依据 | `docs/reference-abts.md` §4（降级为移植冒烟口径） |

> **口径说明**：原计划 M0 做独立最小 Demo 工程。按 `docs/reference-abts.md` §4 降级为
> **移植冒烟测试**——`lib/core/api` 已整体移植自 abts（本机验证过的实现），M0 的任务是
> 证明"移植后的代码在本项目里仍能工作"，而不是重新发明。验证脚本是纯 Dart CLI，
> 与 App 共用同一个 `BiliClient`，避免"冒烟通过、App 里却跑不通"的两张皮。

---

## 总览

| # | 验证项 | 结果 | 说明 |
|---|---|---|---|
| S1 | WBI 签名搜索接口 | ✅ PASS | 「有声小说」「相声」各返回 200，20 条结构化结果，完整请求头 |
| S2 | 分 P 列表 + DASH 音频流 | ✅ PASS（接口层） | 72 分 P 样本 → pagelist → playurl 拿到 2 条 m4a，带 UA+Referer 取流 206；**真机播放待 M2 补**（本机无设备） |
| S3 | 播放地址有效期 | 🚧 部分通过 | deadline 字段推算 ≈ **120 分钟**；T+14min 复测地址仍有效；1h/2h/4h/8h 长周期待后续补测 |
| S4 | 后台播放 + 续播 Demo | ⏸ pending | 本机无 Android 设备 / adb，推迟到 M2 在真机按 P-01~P-08 实测 |

---

## S1 · WBI 签名搜索接口 —— PASS

**方法**：`dart run tool/spike/m0_probe.dart`，匿名调用 `x/web-interface/wbi/search/type`
（搜索类型 0：视频），关键词分别用「有声小说」「相声」。

**结果**：

- 两个关键词均 **HTTP 200**，无 -412 / 403；
- 各返回 **20 条**结构化结果（bvid / title / author / duration / pic 齐全）；
- 标题中的 `<em class="keyword">` 高亮标签已剥除；
- WBI 签名走 `wbi_signer.dart`（nav 取 img_key/sub_key + mixin_key 重排 + MD5），
  mixin_key 按天缓存（当日多次调用只刷新一次）；
- 请求头完整：`UA`、`Referer (https://www.bilibili.com/)`、`Cookie (buvid3=…)`、
  `Origin`、`bili-jct` 均在。

**结论**：abts 的 WBI + 节流 + -412 阶梯退避机制移植后工作正常，搜索链路地基成立。

---

## S2 · 分 P 列表 + DASH 音频流 —— PASS（接口层）

**方法**：从 S1 结果里挑一个**多 P** 视频作样本，逐个走 `view`（取 cid）→ `pagelist` →
`playurl`（fnval=16，fnval=16 = DASH），拿到流地址后带 `UA + Referer` 实际 GET 一次验证可取数据。

**样本**：

| 项 | 值 |
|---|---|
| bvid | `BV1xCJv6bEHx` |
| 标题 | 有声书《离婚后，高冷女总裁后悔了》全集 |
| 分 P 数 | **72** |

**结果**：

- `view` 拿到 cid；`pagelist` 返回 72 个分 P（探测过程中确认存在多 P，非退回单 P 样本）；
- `playurl`（fnval=16）返回 **DASH 结构**：视频流 + **2 条音频流**（m4a，
  一条约 128kbps，一条更低码率备用），带 `id / baseUrl / bandwidth / codecs`；
- 用返回的音频 `baseUrl`，带 `UA` + `Referer: https://www.bilibili.com/video/BV1xCJv6bEHx`
  实际 GET → **HTTP 206 Partial Content**，成功取到 m4s 分片数据（响应头含 `Content-Range`）；
- 验证了 abts 结论：**取流必须带与 playurl 一致的 UA + Referer，否则 403**；
- 流地址与取流参数已存档 `tool/spike/last_play_url.json`
  （url / referer / user_agent / bvid / cid / obtained_at / expires_at）。

**遗留**：「在 Android 真机播放成功」这一步本机无设备无法执行。按
`docs/reference-abts.md` §4 降级口径，接口层 + HTTP 取流已验证；**真机播放归入 M2**，
在真机上按 P-01~P-08 用例实测（含播放页/MiniPlayer/锁屏）。

---

## S3 · 播放地址有效期 —— 部分通过

**方法**：S2 取到地址时记录时间戳，解析 URL 内 `deadline` 字段（Unix 秒），
推算期望有效期；后续用 `--check` 复测同一 URL 是否仍可取流。

**实测**：

| 时刻 | 动作 | 结果 |
|---|---|---|
| T0 = 16:09:58 | 取址（BV1xCJv6bEHx / cid 42822732802） | `deadline=1792750199` → **期望有效期 ≈ 120 分钟**（至 18:09:59） |
| T0+14min = 16:24 | `--check` 复测同一 URL | 状态 `recorded`，deadline 剩 **≈105 分钟**，地址仍有效 |

**分析**：

- 地址有效期由 URL 内 `deadline` 参数直接给出（≈ **120 分钟**），比 abts 实测的 90 分钟
  （`docs/reference-abts.md` R5）更宽松；取 120min/90min 的**较小值 90 分钟**作为
  R5 过期策略的保守基数是安全的；
- R5 过期策略（到期前 5 分钟换源 + 播放中每 30 分钟检查）在此基础上偏保守，方向正确；
- **未完成**：1h / 2h / 4h / 8h 的长周期复测受真实等待时间限制，本次仅得 T+14min 证据。
  后续可用 `--check` 在 1h、2h（预期即将过期）、4h（预期已过期返回 403/失效）继续补测，
  完善 R5 的"过期后实际表现"（403？还能播？）数据。**该项不阻塞 M2 开工**——
  R5 已按保守值设计，长周期数据只是用来调参。

---

## S4 · 后台播放 + 续播 Demo —— pending_device

原计划用 `just_audio + audio_service` 做最小实现验证锁屏控制与杀进程续播。
**本机无 Android 设备、adb 不可用**，无法执行。

**处置**：按 `docs/reference-abts.md` §4 降级口径，S4 归入 **M2 播放核心**，
在真机上按 P-01~P-08 用例实测（含锁屏控制、杀进程续播、断点续播）。abts 已在真机验证过
audio_service 集成，风险低，M2 只需移植 + 实测。

---

## 对后续里程碑的影响

| 影响项 | 结论 |
|---|---|
| M2 能否开工 | **可以开工**。S1/S2 接口地基成立，S3 有保守值兜底，S4 移到 M2 真机做 |
| R5 过期策略 | 保持"到期前 5 分钟换源 + 每 30 分钟检查"，保守基数取 **90 分钟**（deadline 实测 120min 的较小安全值）；长周期数据后续补测调参 |
| 取流约束 | 必须带与 playurl 一致的 **UA + Referer**，已写进 `core/api`，M2 直接复用 |
| 请求纪律 | WBI 日刷新 + 450ms 节流 + -412/-352 阶梯退避移植验证通过，M2 播放轮询复用同一套，**不另起炉灶** |

## 复现步骤

```powershell
# 完整冒烟（S1 搜索 + S2 多P取流 + S3 记录有效期）
dart run tool/spike/m0_probe.dart

# S3 复测：检查存档地址是否仍有效
dart run tool/spike/m0_probe.dart --check
```

> 注：脚本依赖网络与 B 站接口，可能受风控影响偶发 -412；遇 -412 会按阶梯退避自动重试。
