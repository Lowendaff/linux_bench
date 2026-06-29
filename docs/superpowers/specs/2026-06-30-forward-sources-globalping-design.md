# 去程路由追踪源 · Globalping CI 再生 设计

- **日期**:2026-06-30
- **目标**:给「去程路由追踪」(`utils/forward_sources.txt`)持续补充尽可能多的**中国大陆运营商** `--from` 源,通过 CI 定期从 Globalping 探针数据自动再生该文件。

## 1. 背景与关键约束

去程追踪运行 `nexttrace --json --from <param> <本机IP>`。实测确认:**`nexttrace --from` 由 [Globalping](https://globalping.io) 驱动**(`--help`:"Run traceroute via Globalping … from a [location]"),`<param>` 是 Globalping 的位置过滤串(如 `CN+AS4134` = 中国 ∩ AS4134),**无需 NextTrace token**(已实测 `--from CN+AS4134` 返回广东深圳电信探针的真实路由)。

因此**能加的源 = Globalping 当前在中国大陆有在线探针的网络**。实测快照:全网 5063 探针,中国大陆 48 个,分布 20 个 ASN(电信/联通/移动主干 + 各省 + 腾讯云/阿里云/华为云 + 个别有线/小网络)。探针**社区运营、动态上下线**;`CN2/AS4809`、`CMIN2/AS58807` 此刻无探针。

**约束处理**:
- 探针易变 → 运行时失败已被 `run_forward_trace_test` 优雅跳过;CI 周期刷新捕捉新增/淘汰。
- Globalping **探针列表 API**(`GET /v1/probes`)只读、无需鉴权、**不消耗测量配额** → 生成器随便查。
- Globalping **匿名测量** API 有速率限制 → 源数量控制在 **ASN 级别**(每运营商每 ASN 一条,不做 per-city 展开),CN 约 15-20 条。

## 2. 架构(纯增量,不改主脚本)

与现有 `fetch_nf_ix_map` 完全同构。`run_forward_trace_test` 运行时已下载并解析 `utils/forward_sources.txt`,所以**只需让 CI 持续更新该数据文件**:

| 文件 | 操作 | 责任 |
| :--- | :--- | :--- |
| `utils/fetch_forward_sources.py` | 新建 | 查 Globalping → 生成 forward_sources.txt |
| `.github/workflows/fetch_forward_sources.yml` | 新建 | 定时/手动/改脚本时跑生成器,有变化才提交 |
| `utils/forward_sources.txt` | 由生成器再生并提交 | 数据文件 |
| `tests/test_fetch_forward_sources.py` | 新建 | 对生成器纯函数做单元测试(夹具 JSON) |
| `linux_bench.sh` | **不改** | 已能下载解析该文件 |

## 3. 生成器 `utils/fetch_forward_sources.py`

**结构**(把"取数"和"变换"分开,便于测试):
- `fetch_probes() -> list`:`GET https://api.globalping.io/v1/probes`(30s 超时,UA 头),返回 JSON 列表;失败抛异常。
- `build_sources(probes) -> str`:**纯函数**,输入探针列表 → 输出完整 forward_sources.txt 文本。
- `main()`:fetch → build → 写文件;**失败安全**(fetch 失败或 build 出 0 条中国大陆条目 → log + `sys.exit(1)`,**不覆盖**旧文件)。

**`build_sources` 逻辑**:
1. 过滤 `location.country == "CN"` 的探针。
2. 按 `location.asn` 聚合;只保留**有 ≥1 探针**的 ASN。
3. 每个 ASN 定 (分组, 显示名):优先查下方人工 `ASN_INFO` 表;查不到 → 分组 `中国其他`、名取 `location.network` 首段 + 城市(英文亦可),保证"尽可能多"。
4. 按固定**分组顺序**输出:`中国电信 → 中国联通 → 中国移动 → 中国云厂商 → 中国其他`;组内按 ASN 升序。
5. 每条:`<显示名>|CN+AS<asn>`;每个 `#GROUP:` 前留空行。
6. 文件尾**静态附加**非中国分组(见 §5,作为脚本内常量)。
7. 顶部写注释头:生成时间留空占位(由 args 传入或省略,避免每次 diff 抖动——见"实现注意")+ 本工具说明。

**`ASN_INFO`(人工维护的已知中国大陆 ASN → (分组, 名))**:
```python
ASN_INFO = {
    # 电信
    4134:   ("中国电信", "中国电信 163"),
    4809:   ("中国电信", "中国电信 CN2"),      # 当前可能无探针,有则自动出现
    4847:   ("中国电信", "中国电信 AS4847"),
    151185: ("中国电信", "中国电信 (武汉)"),
    # 联通
    4837:   ("中国联通", "中国联通 169"),
    9929:   ("中国联通", "中国联通 A网 (9929)"),
    4808:   ("中国联通", "中国联通 (北京)"),
    17621:  ("中国联通", "中国联通 (上海)"),
    # 移动
    9808:   ("中国移动", "中国移动 CMNET"),
    58807:  ("中国移动", "中国移动 CMIN2"),     # 当前可能无探针,有则自动出现
    56048:  ("中国移动", "中国移动 (北京)"),
    24400:  ("中国移动", "中国移动 (上海)"),
    24445:  ("中国移动", "中国移动 (河南)"),
    56046:  ("中国移动", "中国移动 (扬州)"),
    56047:  ("中国移动", "中国移动 (长沙)"),
    # 云厂商
    45090:  ("中国云厂商", "腾讯云"),
    37963:  ("中国云厂商", "阿里云"),
    55990:  ("中国云厂商", "华为云"),
    # 其他
    17962:  ("中国其他", "深圳天威 (Topway)"),
}
GROUP_ORDER = ["中国电信", "中国联通", "中国移动", "中国云厂商", "中国其他"]
```
未列入但有探针的 ASN(如 AS136188/146817/153393 等)→ `中国其他`,名 = 自动派生。

## 4. 命名/分组规则细节

- 已知 ASN:用 `ASN_INFO` 的中文名(`显示名|CN+ASxxxx`)。
- 未知 ASN:分组 `中国其他`,名 = `f"{net} (AS{asn})"`,其中 `net` 取 `network` 字段去掉常见后缀后的首 2-3 个词或城市;保证唯一、可读。
- `CN2/AS4809`、`CMIN2/AS58807` 在 `ASN_INFO` 里但只有**当前有探针**才会被输出(因为第 2 步只保留有探针的 ASN)。

## 5. 非中国静态尾块(生成器内常量,原样保留)

```text
#GROUP:亚太地区
香港 PCCW|HK+AS3491
香港 HGC|HK+AS9304
日本 NTT|JP+AS2914
日本 KDDI|JP+AS2516
新加坡 Singtel|SG+AS7473
韩国 KT|KR+AS4766

#GROUP:欧洲
德国 DTAG|DE+AS3320
英国 BT|GB+AS5400
法国 Orange|FR+AS5511

#GROUP:北美
美国 Cogent|US+AS174
美国 Lumen|US+AS3356
美国 GTT|US+AS3257
```

## 6. CI 工作流 `.github/workflows/fetch_forward_sources.yml`

仿 `fetch_nf_ix_map.yml`:
- 触发:`workflow_dispatch`;`push`(paths: 本 yml + `utils/fetch_forward_sources.py`);`schedule: cron "0 1 * * 1"`(周一 01:00 UTC,错开 nf_ix_map 的 00:00)。
- `permissions: contents: write`;`concurrency` 分组。
- 步骤:checkout(fetch-depth 0)→ setup-python 3.12 → `python utils/fetch_forward_sources.py` → 若 `git status --porcelain utils/forward_sources.txt` 有变化则 `add/commit/pull --rebase/push`(commit msg:`actions: Update forward trace sources`)。

## 7. 实现注意

- **避免无意义 diff**:生成器输出**确定性**(分组顺序固定、组内按 ASN 排序)。注释头**不写**精确时间戳(否则每周必产生 diff 即使数据没变);若要时间戳,由 CI 通过环境变量/参数传入并放在一行,使"无数据变化时不提交"逻辑仍成立——**默认不写时间戳**,只在数据变化时提交。
- **失败安全**:任何异常或 0 条 CN 结果 → `sys.exit(1)` 且不写文件。

## 8. 测试

- **单元测试** `tests/test_fetch_forward_sources.py`(**纯 stdlib `unittest`,不引入 pytest 依赖**;独立运行 `python3 tests/test_fetch_forward_sources.py`,**不并入 bash 的 `run_all.sh`**):对 `build_sources()` 喂一份**夹具探针 JSON**(含:已知 ASN 多探针、已知 ASN 无探针应不出现、未知 ASN 走"中国其他"自动命名、非 CN 探针被忽略),断言:分组顺序、条目格式 `名|CN+ASxxxx`、排序、静态尾块存在、`build_sources([])`(无 CN)触发空结果(由 main 转为 exit 1)。
- **手动冒烟**:本地/CI 跑生成器 → 人眼核对输出;在测试机 45.146.243.36 用再生后的 `forward_sources.txt` 跑一次去程追踪,确认多个 `CN+ASxxxx` 源返回真实路由。

## 9. 范围外(本次不做)

- 不动 `linux_bench.sh` 与 `run_forward_trace_test`。
- 不做 per-city 展开、不动非中国分组的内容、不接入 Globalping 鉴权 token。
- 运行时速率限制只做"控制源数量 + 文档提醒",不在脚本里加限流逻辑。
