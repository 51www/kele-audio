# 儿童白名单人工终审流程（M6 / PRD §7.3）

> 目标：儿童模式开启后，发现页内容 100% 可由人工解释来源。
> 每周投入 ≤ 1h；本流程不改代码即可执行（配置热修复通道）。

## 1. 白名单的三层口径

| 层 | 载体 | 说明 |
|---|---|---|
| L1 封闭源（最稳） | `queries[].source = "up" / "series"` | 人工确认过的 UP 主/合集 id，内容完全封闭 |
| L2 关键词白名单 | `queries[].source = "search"` + `filter: "children"` | 标题/标签/UP 名必须命中儿童特征词，且不命中成人否决词 |
| L3 黑名单 | `blacklist_up_mids` | 命中 UP 一律剔除，无论来源 |

当前内置白名单（`assets/api/children_config.json`）五类均使用 L2；
每类出现过的优质 UP / 合集，终审通过后升级为 L1 封闭源（改动见 §3）。

## 2. 每周终审动作（≤ 1h）

1. **抽样**：App 开儿童模式，五个分类各翻 1 页（≥4 条/类）。
2. **核对**：逐条问三个问题——
   - 内容是否适合儿童独立收听？
   - 标题/标签是否命中儿童特征词（可解释）？
   - 是否混入成人向内容（恐怖/言情/直播引流等）？
3. **记录**：不合格内容记下标题 + UP 名 + bvid/合集 id。

## 3. 处置方式（改 `assets/api/children_config.json`，或发远端覆盖 JSON）

- **单条不合格**：把该 UP mid 加入对应分类的 `blacklist_up_mids`；
- **同类反复出现**：收紧该分类关键词（加否决词需同步
  `DiscoverSource.kidNoiseWords`，属代码改动）；
- **优质源确认**：把 UP mid / 合集 id 加入 `queries`（`up`/`series` 封闭源），
  并可删除对应 search 查询（升级为 L1）。

## 4. 远端覆盖（不发版更新）

`children_config.json` 顶层 `remote_config_url` 指向任意静态托管 JSON
（GitHub Raw 均可），结构与本文件同；App 每 6h 拉一次，失败静默沿用
上次缓存（`children_config_remote_json`），再失败用内置兜底。

## 5. 升级为代码改动的红线

以下情况必须走代码 review，不许只改配置：

- 新增/修改否决词表（`kidNoiseWords`）或特征词表（`kidHintWords`）；
- 过滤逻辑本身（`passesChildrenFilter`）；
- 时长门槛从「建议」变「硬约束」的口径调整。
