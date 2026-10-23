# abts（阿B听书）参考答案对照表

| 项目 | 内容 |
|---|---|
| 参考项目 | https://github.com/fengqiao57/abts.git （阿B听书 v1.2.0，Flutter，**MIT 协议**） |
| 本地克隆 | `C:\Users\EDY\AppData\Local\Temp\opencode\abts`（分析用，临时目录） |
| 更新日期 | 2026-10-23 |
| 结论 | **abts 与本项目几乎同赛道**（B 站听书播放器，Android、免登录、分P连播、断点续播、离线缓存），PRD 中 R1/R2/R5/R6/R8 五大风险均已在该仓库中有经生产验证的解法 |

> **使用约定**：
> 1. 布局与主题**自主设计**（用户已明确），abts 只参考**逻辑与数据层**；
> 2. 代码为 MIT 协议，可直接复制/改写，但需在 `about_page` 保留其开源声明与致谢；
> 3. **不抄**的部分：友盟统计（`umeng_common_sdk`）、Windows 目标、内部调试打印。

---

## 1. 技术栈选型差异（PRD 需要更新的决策点）

abts 的实战选型与我们 PRD/M1 的计划有 4 处不同，**建议全部改为与 abts 一致**（这些选择正是为听书场景验证过的）：

| 领域 | PRD/M1 原计划 | abts 实际 | 建议 |
|---|---|---|---|
| 播放内核 | `just_audio`(ExoPlayer) | **`media_kit`**（+ `media_kit_libs_audio`） | 采纳 abts：`open(url, httpHeaders:)` 原生支持带 UA/Referer 取流（B 站 CDN 必需）、候选地址逐个 fallback、倍速/seek 控制精细。**注意**：不引入 ffmpeg（libs_audio 仅音频），包体积达标（abts APK ~26MB） |
| 状态管理 | riverpod | **`provider`** | 采纳 abts：应用规模不大，provider 足够，学习成本低 |
| 本地存储 | SQLite/drift | **`shared_preferences`（JSON）** | 采纳 abts：书架/进度/缓存索引全用 SP，实测够用（进度按 cid 累计，超 2000 条清理）。MVP 不引入数据库，降低 M1 成本 |
| HTTP | dio | dio | 一致 |

其余关键依赖：`audio_service`（后台/锁屏）、`cached_network_image`、`crypto`（WBI md5）、`path_provider`、`qr_flutter`（扫码登录）、`share_plus`、`permission_handler`。

---

## 2. 风险点 ↔ abts 答案（PRD 第 2 章对照）

### R1 接口无官方保障 → `core/network/`（三个文件解决）

| 答案 | 位置 | 要点 |
|---|---|---|
| **WBI 签名完整实现** | `wbi_signer.dart`（66 行，独立无依赖） | `_mixinKeyEncTab` 置换表 + mixin key + 参数排序过滤 `!'()*` + md5。**可整文件直接复用** |
| **端点常量集中管理**（正是 PRD R1"接口隔离"要求） | `api_config.dart` | 所有 URL 集中在一个类：nav / searchType(WBI) / spaceArcSearch(WBI) / seasons_series_list / seasons_archives_list / view / pagelist / playUrl(WBI) / activateBuvid / qrGenerate / qrPoll |
| **WBI key 日刷缓存** | `bili_client.dart` L101-106, L283-308 | 从 `nav` 接口取 `wbi_img.img_url/sub_url`，**按天过期**，SharedPreferences 持久化（`img|sub|时间戳`），启动本地恢复、进主界面后台刷新 |
| **Referer 规则实测结论** | `bili_api.dart` 多处 | ① 搜索接口必须带 `origin/referer = search.bilibili.com`；② polymer 合集接口必须带 `referer = space.bilibili.com/{mid}` 才返回数据；③ 播放/下载 CDN 必须带 UA+Referer 头 |
| **匿名可用性实测结论**（重要！） | `bili_api.dart` L336-343 注释 | `/x/space/wbi/arc/search` **未登录基本必被风控（-352/412）**；`seasons_series_list` 匿名可用；搜索接口做最后兜底。→ 直接修正 PRD §7.2 的 `up_mid` 数据源优先级 |

### R2 风控限流 → `core/network/bili_client.dart`（440 行，PRD 最核心的参考文件）

| 答案 | 位置 | 要点 |
|---|---|---|
| **游客请求节流** | L42, L196-204 | 全局最小间隔 **450ms**（`QueuedInterceptorsWrapper` 前置 `_throttle`），注释：官方与主流第三方都刻意放慢游客节奏 |
| **buvid3/buvid4 本地生成** | L458-472 | `genBuvid3()`：UUID 大写 + 5 位随机 + `infoc` 后缀 |
| **gaia 风控闭环激活** | L140-173 | 先本地种入 buvid3/buvid4 → POST `ExClimbWuzhi` 上报伪设备指纹 payload，把匿名游客伪装成"活跃设备"，"海外 IP 尤其需要" |
| **Cookie 预热 + 分层初始化** | L66-136 | `initLocal()`（启动关键路径，零网络：恢复 Cookie/WBI 缓存）→ `warmupIfNeeded()`（进主界面后后台：种 buvid、激活、刷 WBI key，失败静默） |
| **-412/-352 阶梯退避** | L251-266, L341-351 | 识别口径统一：HTTP 412/403 **或** body code -412/-352；退避阶梯 `[1200, 2600, 5000]`ms；首次命中执行 `_mitigateRisk()`（补 buvid + `b_nut` + 重新 warmup） |
| **搜索的 v_voucher 极验风控** | `bili_api.dart` L120-126 | `result == null && v_voucher != null` → 等 `1500ms × attempt` 重试 3 次 |
| **取流接口单独退避** | `bili_api.dart` L252-285 | playurl 连续取地址最易触发 -412/-352：重试 3 次、退避 `1800ms × attempt`；**"响应无可用音轨"也视为失败**（防止批量缓存静默跳集） |
| **下载限速** | `cache_store.dart` L371 | 批量缓存两集间隔 1500ms |

### R3 版权与分发 → `README.md` 免责声明（L166-173）

6 条免责声明可直接改写使用（非关联声明、内容来自公开链接、仅供个人学习、支持正版、侵权联系即处理、后果自担）。abts 的做法印证了 PRD 的定位：**仅在线播放、不存储不修改不二次分发、个人使用**。

### R4 内容分类与筛选 → `data/seed_books.dart` + `bili_api.dart` 过滤器

| 答案 | 位置 | 要点 |
|---|---|---|
| **分类模型** | `seed_books.dart` L4-31 | `DiscoverCategory{label, keyword, icon, anchors[]}` + `AnchorPick{name, works, keyword, color}`。**分类 = 一个搜索关键词 + 一组精选主播（关键词直达）**，本地种子数据保证无网可看 —— 比 PRD §7.2 的 JSON 配置更简单，MVP 可先用硬编码种子，二期再做远端下发 |
| **精选主播清单**（现成运营成果） | `seed_books.dart` 全文 | 周建龙/紫襟/王明军/艾宝良/李野默/青雪（有声小说）、光合积木/音熊联萌/729声工场/边江/北斗企鹅/冠声（广播剧）等，单田芳/刘兰芳/郭德纲（评书相声）—— 可直接作为我们发现页种子 |
| **听书内容四级过滤规则** | `bili_api.dart` L35-81 | ① 噪音词一票否决（漫推/解说/鬼畜/混剪…）；② 标题含听书词 ≥5 分钟；③ **B 站 195 分区（动态漫.广播剧）≥10 分钟**；④ 简介/标签含听书词 ≥30 分钟；⑤ 搜索词本身是题材词 ≥30 分钟。听书特征词表 18 个词现成可用 |
| **搜索补搜策略** | `bili_api.dart` L151-192 | 原关键词搜 → 命中 <6 条时补搜 `"{关键词} 有声小说"` 合并去重，**仅第 1 页补搜**（防翻页请求翻倍） |
| **儿童模式过滤** | — | abts 无儿童内容。**自建方案**：沿用 `AnchorPick` 白名单结构（儿童主播/合集关键词），加上"只走合集/系列封闭列表 + 人工终审"，实现成本与 abts 分类一致 |

### R5 播放地址时效 → `player/book_player.dart`

| 答案 | 位置 | 要点 |
|---|---|---|
| **URL 不落库** | L60, L788-789 | 仅存内存 `Map<cid, (url, ts)>`，**有效期 90 分钟**，上限 6 条；持久化层只存 bvid/cid |
| **候选地址 = 备用线路** | L785-824 | playurl 返回的每条音轨 `baseUrl + backup_url` 全部进候选列表，`http://` 统一转 `https://`，按 bandwidth 降序（192K 优先于 64K），flac/dolby 兜底 —— 逐个尝试直到打开成功 |
| **CDN 请求头** | L778-782 | `open(Media(url, httpHeaders: {User-Agent, Referer}))` —— **不带头必 403/412**，这是选 media_kit 的直接原因（just_audio 需要自定义 DataSource factory 才能带同款头） |
| **断流自动重连** | L266-283, L325-411 | 双触发：播放器 error 事件 + **看门狗**（5s 一轮，播放中且位置 >40s 无推进判定断流）；重连流程：会话代号防"停了又响" → 记住 resumeMs → 清 URL 缓存重取候选 → 逐个 open → seek 回原位（600ms 后校验落点，偏差 >5s 再 seek 一次）；看门狗**故意不随 stop() 取消** |

### R6 播放工程细节 → `player/book_player.dart` + `bili_audio_handler.dart` + `services/audio_focus.dart`

| 答案（PRD P-01~P-08） | 位置 | 要点 |
|---|---|---|
| P-03 断点续播 | L246, L1183-1215 | position 回调 → **debounce 2s** 落库；pause/切章/打断/退出时手动 `flushProgress()`；存 `ShelfStore`（lastCid/index/positionMs + 按 cid 累计 chapterProgress，只前进不后退） |
| P-03 已知坑修复 | L1189-1209 | 刚起播时 media_kit 时长未解析（`currentDuration <= 0`）会丢整条进度 → **用 B 站分 P 自带 duration 兜底** |
| P-01/P-02 后台+锁屏 | `bili_audio_handler.dart`（61 行薄桥接） | `BaseAudioHandler` 全转发；`_pushState` 500ms 节流推送 PlaybackState；另有 2s 一次的"系统状态校正器"；**缓冲状态刻意不上报**（Android 会显示成暂停图标导致锁屏状态漂移） |
| P-04 跨章续播 | `playBook(resumeIndex, resumeMs)` | 恢复到"最后章节 + 秒级进度" |
| P-05 失效自愈 | 见 R5 | — |
| P-06 线控/蓝牙 | `audio_focus.dart` | `EventChannel('abts/audio_focus_events')`：lost/interrupted/ducked/gained/noisy 五事件，**拔耳机（noisy）→ pause** |
| P-07 音频焦点 | L299-320, L446-480 | **自建原生通道**（非 audio_session）：来电 interrupted → 暂停并标记 `_pausedByInterruption`（不 abandon 焦点）→ gained 后自动恢复；被永久抢占 lost → 暂停不恢复；提示音 ducked → 音量 ×0.3（下限保护 0.05） |
| P-08 睡眠定时 | L1218-1238 + `sleep_timer_page.dart` | `Timer.periodic` 每秒递减，归零 pause（非 stop，进度照常保存）；预设 10/15/30/45/60/120 + 自定义 1~720 分钟；**"本集播完即停"是独立开关**（completed 回调：回退片尾 15s + pause + 进度指向下一章） |
| 倍速持久化 | L67-71, L143-173 | SharedPreferences `abts_rate`；11 档 0.5x~3.0x；**关键坑：每次 `open()` 换源后 media_kit 速率复位**，须在在线/本地/重连三处显式恢复 |
| 分P连播 | L199-230 | `stream.completed` 监听；**过滤伪 completed**（open 换源可能抛一次：`_loading` 状态 + 位置离结尾 <3s 双判断）；已完成章节打 ✓（95% 提前量）；已听章节置灰 |
| ±15 秒快进退 | bili_audio_handler L48-51 | seek(currentPosition ± 15s) |

### R8 存储管理 → `core/storage/cache_store.dart`（1100+ 行，完整离线缓存体系）

| 答案 | 位置 | 要点 |
|---|---|---|
| 队列模型 + 状态机 | L181-201, L320-359 | 三层：`_entries`（完成索引）/ `_queue + _active`（持久化任务）/ `_tasks`（UI 进度）；状态：排队→下载中→done/failed；**Dart 层串行下载**（`_draining` 互斥），Dio download 到 `.part` → 校验非空 → rename |
| **杀进程后续传** | L705-761 | pending 队列（**含正在下载的那一项**）每集结束即落盘；启动恢复后延迟 4s（等 WBI/buvid 预热）去重重新入队 |
| **启动对账** | L772-832 | `_reconcile()` 双向校验：索引→磁盘（文件缺失/0 字节 → 摘除）；磁盘→索引（孤儿文件含 `.part` → 删除）；结果写事件日志 |
| 目录与命名 | L54, L630-645 | **应用内部私有目录** `audio_cache/`（与索引同分区，覆盖升级不丢）；扁平命名 `{bvid}-{cid}.m4a`；写盘路径 = 播放路径（同一拼接函数） |
| **失效判断单一入口** | L1142-1165 | `cacheFilePath()`：存在且 >0 字节才有效；播放器**禁止自己拼路径查 exists()**（两处判断结论曾相反导致误删） |
| **打开失败不删缓存** | L1167-1188 | `dropIfBroken()`：只有"确认文件不存在/0 字节"才删索引；open 异常但文件完好 → 保留（曾误删 194MB《三体》缓存的修复） |
| 空间预检 | L545-549, L1010-1017 | 按真实码率 **16500 字节/秒 + 2MB 余量 × 1.2 安全系数**（旧值 16kbps 低估 8 倍）；可用空间走原生 `abts/storage.freeBytes` |
| 迁移安全策略 | L838-906 | 外部目录 → 内部目录：**复制 → 校验大小一致 → 才删源**；只有"迁移成功且旧目录已空"才删旧目录 |
| 通知栏进度 | `cache_notifier.dart`（65 行） | `MethodChannel('abts/cache_notify')` update/cancel；整数百分比节流；队列空自动 cancel |
| 失败可见可重试 | L207-253, L446-477 | `CacheFailure` 列表按 bvid 分组一键重试；事件日志（60 条落盘）弥补 release 下无 debugPrint |

---

## 3. 其余可直接参考的功能实现

| PRD 功能 | abts 位置 | 说明 |
|---|---|---|
| 书架/进度存储 | `shelf_store.dart`（261 行） | SP 单 key `abts_shelf`，JSON 数组；`ShelfBook` 含 lastCid/positionMs/chapterProgress/collectionTime；整本书进度百分比算法现成 |
| 关注 UP 主 | `follow_store.dart` | 同款 SP 模式 |
| 扫码登录 | `bili_api.dart` L585-616 + `login_page.dart` | qrGenerate → qrPoll 轮询（0=success/86038=expired/86090=scanned/86101=waiting），CookieJar 自动合并 SESSDATA 持久化；二维码可存相册 |
| 检查更新 | `services/app_update.dart` | 对比 GitHub Releases，可直接换成我们自己的仓库 |
| 主题模式（跟随系统/浅/深） | `core/theme/` + `theme_page.dart` | 只参考**机制**（ThemeMode 切换 + SP 持久化），配色自主设计（见 `docs/theme.md`） |
| 发现页无网降级 | `discover_page.dart` | 无网列出本地种子/已缓存书籍 |
| 接口探针调试工具 | `tool/` | 独立 `dart run` 脚本，M0 验证可借鉴 |

---

## 4. 对里程碑计划的修订建议

| 里程碑 | 修订 |
|---|---|
| **M0 技术验证** | **降级为"移植冒烟测试"**：S1（WBI 搜索）、S2（取流播放）、S4（后台+续播）的代码答案已在 abts 中，验证目标改为"确认 abts 当前实现仍然可用（接口未变）+ media_kit 在我们工程里能跑通"。仅剩 S3（URL 有效期，abts 取 90 分钟）可选实测 |
| **M1 工程骨架** | 技术栈改为 abts 同款（media_kit/provider/SP/dio）；可直接移植 `core/network/` 三件套 + 主题机制壳 |
| **M2 播放核心** | 工期可从 5 天压缩到 **3 天左右**：移植 `book_player.dart` + `bili_audio_handler.dart` + `audio_focus.dart`，工作量主要是裁剪埋点/调试代码 + 自主 UI 播放页 |
| **M3 发现页** | `bili_api.dart` 整体移植（搜索过滤器/补搜/合集游标/二维码登录全在内）；分类种子结构照搬、内容换成我们的分类（含儿童） |
| **M4 书架** | `shelf_store.dart` 直接移植 |
| **M5 我的** | 设置/关于/更新检查均有参考 |
| **M6 儿童模式** | **无现成答案，仍是自建重点**：基于 `AnchorPick` 白名单结构做儿童内容源 + 主题切换 |
| **M8 离线缓存** | `cache_store.dart` 体系完整（1100 行），**可从 M8 提前**——因为在线/离线统一播放的设计让播放器一开始就按"缓存优先"架构写，避免 M2 返工。建议 M2 只预留接口，M8 整体移植 |

### 移植时的改造清单

1. **剥除统计**：`umeng_analytics.dart`、`umeng_common_sdk` 依赖、全部埋点调用；
2. **主题与布局重写**：按 `docs/theme.md` 五主题方案自主设计（儿童模式是 abts 没有的）；
3. **分类扩展**：发现页分类从"纯有声小说"扩到 相声/讲书/音乐/儿童（abts 的过滤器偏听书，音乐类需放开 `_isAudiobookItem` 的时长/关键词门槛）；
4. **统计功能**：abts 无听书统计，`play_log` 聚合自建（可在 `_saveNow` 落库处顺带埋日志）；
5. **命名空间**：MethodChannel 前缀 `abts/` → 我们自己的前缀；包名、Logo、README 替换；
6. **保留 MIT 声明**：关于页加致谢。

---

## 5. 更新后的工作量评估

| 里程碑 | 原预估 | 新预估 | 说明 |
|---|---|---|---|
| M0 | 3 天 | 1 天 | 冒烟验证即可 |
| M1 | 2 天 | 2 天 | 栈切换，骨架工作量相近 |
| M2 | 5 天 | 3 天 | 移植为主 |
| M3 | 5 天 | 3 天 | API 层整体移植 |
| M4 | 3 天 | 1.5 天 | shelf_store 直接移植 |
| M5 | 3 天 | 2 天 | 参考充分 |
| M6 | 3 天 | 3 天 | 自建，无参考 |
| M7 | 3 天 | 3 天 | 不变 |
| **合计** | **27 天** | **约 18.5 天** | 前提：M6 儿童模式与 UI 重写不超支 |
