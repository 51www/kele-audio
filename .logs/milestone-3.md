# 里程碑工作记录 · M3 发现页与详情页

| 项目 | 内容 |
|---|---|
| 日期 | 2026-10-26 |
| 范围 | M3 发现页与详情页（内容源配置 / API 聚合 / 发现页 UI / 详情页 UI / 缓存策略） |
| 环境 | Windows 11 · Flutter 3.47.7 / Dart 3.13.5 · Node 22（dev proxy）· playwright-cli v0.1.22 |
| 分支 | `feat/m3-discover`（从 `main`（tag `m2`）切出） |

---

## 一、本次完成内容

### 架构决策

| 决策 | 理由 |
|---|---|
| 内容配置 `assets/api/content_config.json` + `ContentConfig.builtIn()` 双兜底 | 远端可覆盖、断网有内置回退；loader 镜像 `ApiConfigLoader`（bundled → remote，KV TTL 6h，静默降级）。删除原 `discover_seed.dart` 硬编码 |
| 聚合三源 `ContentQuery`：`search`（分页）/ `up`（投稿+合集）/ `series`（`season:123` 无需 mid，`series:456@<mid>` 编码） | 合集/UP 优先、搜索补充；`season:` 实测不需 mid、`series:` 必须 mid（`tool/spike/season_probe.dart` 验证） |
| 搜索串行而非并发 | 并发会击穿节流（≥450ms/请求），风控代价高 |
| `v_voucher`/-412 双层退避 | 客户端内置 `[1200,2600,5000]ms` 先走，再补 3 次 1500ms×attempt |
| Web 封面走 `/img?u=` 同源反代 | 浏览器在此环境无法直连 hdslb CDN；原生端仍走 `CachedNetworkImage` 磁盘缓存 |
| Web 封面用 `Image.network`，原生用 `CachedNetworkImage` | flutter_cache_manager 的 IndexedDB 文件系统在 playwright 无任何请求发出；原生端保留磁盘缓存（里程碑 ⑤ 主体） |
| 详情章节目录用 `CustomScrollView` + `SliverList` | 真懒加载：232 章只构建视口附近，长列表不卡 |
| 进度标记读 `PlayHistoryDao.forAlbum` | `percent ≥90` → 已听完，`1–89` → 在听 x%，`0` → 未听 |

### 代码落地（lib/）

- **配置**：`core/api/content_config.dart`（5 分类：推荐/有声书/相声曲艺/讲书/音乐，含搜索词、up_mids、黑名单、`cache_ttl_minutes`）
- **API**：`core/api/discover_source.dart`（聚合核心：`_toInt` 兼容字符串数字、合集嵌套 `meta` 解包、`season:`/`series:` 分派、噪声一票否决 + 时长/标题双门槛过滤、mid→upName 经 `/x/web-interface/card`、`BiliPaths.userCard`）
- **缓存**：`core/data/discover_cache.dart`（KV JSON，TTL 30min，`allowStale` 断网兜底，损坏视为未命中）
- **UI**：`features/discover/album_card.dart`（`CoverImage` + `resolveUrl` 同源改写 + 16:9 封面 + 字母渐变占位）、`category_feed.dart`（骨架屏/空态/错误态+重试/离线横幅/触底分页/下拉刷新）、`discover_page.dart`（横向 Tab + `IndexedStack` 保滚动位）、`album_detail_page.dart`（专辑信息区 + 播放全部 + 章节目录 + 进度标记 + 懒加载）
- **DI/装配**：`di.dart`（`contentConfig` / `discoverSource` / `discoverCache` 三字段 + bootstrap）、`app.dart`（3 个新 Provider）、`pubspec.yaml`（assets 加 `assets/api/content_config.json`）
- **删除**：`features/discover/discover_seed.dart`（被 `content_config.dart` 取代）
- **Web 反代**：`tool/dev_proxy.mjs` 新增 `/img?u=<url>` 封面图反代

### 测试

- `test/discover_test.dart` 新增：时长解析（`mm:ss` 无上界，如 `25724:11`）、音频/普通分类过滤规则、合集/UP 实体转换（用真实 probe 形状）、配置加载（含真实 asset JSON）、缓存 TTL/过期/损坏
- `test/widget_test.dart` 适配：flutter_test HTTP→400 走错误态；新增 `pumpThroughLoad`（12×600ms，因 `pumpAndSettle` 在 450ms 节流 Timer 挂起时提前退出）；`find.text` 跨 `IndexedStack` 断言需 `skipOffstage: false`

---

## 二、M3 准出条件逐条核对

| # | 条目 | 结果 | 证据 |
|---|---|---|---|
| 1 | 5 个分类均能加载出内容，切换分类保留滚动位置 | ✅ 浏览器实测 | 5 分类逐个点击加载（推荐/有声书/相声曲艺/讲书/音乐，真实 B 站内容 + 封面）；滚动后切走再切回，两张截图逐像素一致；截图 `m3-discover-{rec,xiaoshuo,xiangsheng,jiangshu,music}.png`、`m3-tab-scroll-keep.png` |
| 2 | 详情页章节列表完整，点击任意章节可播放 | ✅ 浏览器实测 | 232 章目录完整（滚动到 142–157 章）；点第 150 章进入播放页并起播（00:04/12:28，章节 232）；截图 `m3-detail-top.png`、`m3-detail-lazy-load.png`、`m3-chapter-playing.png` |
| 3 | 断网进入发现页：展示缓存内容 + 断网提示，不白屏 | ✅ 浏览器实测 | 代理 `API_BASE` 改死端口 `127.0.0.1:9` + 缓存时间戳改旧 2h；页面展示过期缓存内容 + 红色横幅「当前网络不可用，正在展示缓存内容」；截图 `m3-offline-cache.png` |
| 4 | 连续翻页 ≥3 页无异常；请求频率符合节流约定（≥450ms） | ✅ 浏览器实测 | 连续滚动触发 19 页（代理日志 `page=1..19`）；`performance.getEntriesByType('resource')` 实测 9 个搜索请求相邻间隔最小 637ms（阈值 450ms）；截图 `m3-pagination-deep.png` |

**判定**：**准出条件 4/4 全部通过，M3 完成。**

---

## 三、质量关

| 检查 | 结果 |
|---|---|
| `flutter analyze` | **0 issues** |
| `flutter test` | **31/31 全绿**（M3 新增 8 + M2 播放 10 + M1 冒烟 + 桥接回归等） |
| `flutter build web --profile --no-wasm-dry-run` | 成功 |
| 浏览器实跑 | playwright-cli，视口 430×932，11 张截图 `docs/shortscreen/m3-*.png` |

### 浏览器实测路径（可复现）

```
发现页 5 分类逐个加载 → 推荐页滚动 900px → 切有声书 → 切回推荐（滚动位保留）
→ 切相声曲艺/讲书/音乐 → 点相声合集卡片 → 详情页 232 章
→ 滚到第 142–157 章（懒加载）→ 点第 150 章 → 播放页起播
→ 回发现页连续滚动 19 页（节流 ≥450ms 实测最小 637ms）
→ 代理改死端口 + 缓存改旧 → 重载 → 过期缓存 + 离线横幅，不白屏
```

---

## 四、踩坑记录

| 坑 | 处置 |
|---|---|
| 封面永远不渲染（`CachedNetworkImage` 和 `Image.network` 都零请求） | 根因是 `_fixedHeight` 扩展里 `SizedBox(width: w, height: w*9/16)` **漏了 `child: this`**，`CoverImage` 被丢弃从未挂载 —— 与网络/CORS/缓存管理器全无关。修复后 23 个 `/img` 请求立即发出 |
| B 站搜索字段有时是字符串（`typeid` "195"、`numResults` "1000"） | 统一走 `_toInt` helper 解析 |
| `seasons_series_list` 项是 `{archives, meta, recent_aids}`，`meta` 嵌套 | `_upCollections` 解包 `raw['meta']` |
| `season:` 无需 mid，`series:` 必须 mid | `tool/spike/season_probe.dart` 实测；`series:456` 编码成 `series:456@<mid>` |
| 浏览器直连 hdslb CDN 失败（此环境无外网/跨域） | `dev_proxy.mjs` 加 `/img?u=` 反代；`CoverImage.resolveUrl` 用 `Uri.base.resolve` 补成绝对地址（相对地址会让 `Image.network` 的 HttpClient shim 静默零请求） |
| playwright 坐标点击偶发不命中 Tab | CanvasKit 无 DOM 语义，坐标需按实际布局反推；用 `page.mouse.click(x, y, {delay})` 比 down/up 分步更稳；点击底部导航/卡片同理 |
| 缓存新鲜时直接秒开、不发请求 → 断网无「离线横幅」（因为压根没试网络） | 这是设计行为（TTL 内秒开）；要验证「过期缓存 + 断网提示」需先把 `saved_at` 改旧超 TTL |
| shared_preferences Web 存的是双重 JSON 编码 | 改缓存时间戳要 `JSON.parse` 两层再包回去 |
| widget test 卡在 450ms 节流 Timer | `pumpAndSettle` 提前退出；改用 `pumpThroughLoad`（12×600ms） |
| Flutter service worker 缓存旧 bundle | `caches.keys()` delete + `serviceWorker.getRegistrations()` unregister；之后 goto 加 `?cb=<ts>` 防缓存 |

---

## 五、遗留项

- 加入书架 SnackBar 长时间不消失挡住底部导航（M2 遗留，未修）
- Web 端封面无磁盘缓存（用 `Image.network`），原生端 `CachedNetworkImage` 磁盘缓存已接
- 物理耳机实按键留 M7（无硬件）
