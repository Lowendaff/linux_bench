# 可扩展的 iperf3 测试节点 设计

- **日期**:2026-06-30
- **目标**:把 iperf3 带宽测试从「硬编码两组、每次全测」升级为「**按地区分组的丰富目录 + 运行时按地区/数量选择**」。在 `utils/iperf3_servers.txt` 中按地区(亚太/欧洲/北美/南美/大洋洲/非洲)收录尽可能多的优质公共节点,默认只全测**亚太**,其余地区可按需 opt-in;同时删除已失效的「国内组」与脚本内的青毅云推广。

## 1. 背景与关键约束

**现状**:`get_iperf3_servers()`(`linux_bench.sh:1652`)运行时下载 `utils/iperf3_servers.txt`,但解析器把组名**硬编码**成恰好两组(`国际节点`/`国内节点`),任何其它 `#GROUP:` 分组里的节点被**静默丢弃**(`linux_bench.sh:1674-1678`)。`run_iperf_test()` 对两组用**不同测试逻辑**,并在国内段内嵌一段青毅云推广。

**运行时长(硬约束)**:`run_iperf_once`(`linux_bench.sh:1623`)每次跑 iperf3 `-t 5`(5 秒),失败重试 2 次、每次 `timeout 15`。每个国际节点要跑「每个启用的 IP 版本 × (send + recv)」:

- 同时支持 v4+v6 的节点 ≈ 4 × 5s = **~20 秒/节点**(顺利时)
- 死/忙节点最坏 15s × 2 × 4 = **近 2 分钟/节点**

因此「尽可能多」不能等于「每次全测全部」,否则一轮 iperf 会到 15–60+ 分钟,且大量公共节点 busy/掉线产生 `--`/`busy` 垃圾行。**调和方式 = 丰富目录(收得多)+ 运行时选择(默认只测亚太,其余按需)**。

**公共节点可靠性**:公共 iperf3 服务器会下线、限速、改端口。设计上以「组内顺序=优先级」把最稳的排前面,并由现有的 busy 重试 + `timeout 15` 兜底。南美/大洋洲/非洲的公共 iperf3 本就稀疏,覆盖「重点城市」属尽力而为(见 §3)。

## 2. 范围与改动总览

| 文件 | 操作 |
| :--- | :--- |
| `utils/iperf3_servers.txt` | 重构为 6 个地区分组的丰富目录;删除 `#GROUP:国内节点` 及两个青毅云节点 |
| `linux_bench.sh` · `parse_args` | 新增 `--iperf-all` / `--iperf-region=` / `--iperf-per-region=` 三个开关 + 校验 |
| `linux_bench.sh` · 顶部常量 | 新增 `IPERF_PRIORITY_GROUP`、`IPERF_DEFAULT_PER_REGION` 及对应运行时变量 |
| `linux_bench.sh` · `get_iperf3_servers` | 重写为支持任意 `#GROUP:`;删除 `locs_cn` |
| `linux_bench.sh` · 选择逻辑(新增纯函数) | `iperf_build_plan`:解析结果 + 开关 → 选中的 `(地区, 节点)` 有序列表 |
| `linux_bench.sh` · `run_iperf_test` | 删除整段国内测试 + 青毅云推广;改为遍历选中地区、按地区打印 `###` 子标题 |
| `README.md` | 文档新开关;**保留**致谢区 `YOUTHIDC` 链接(仅删脚本内推广) |
| `tests/` | 新增 `iperf_build_plan` 的纯逻辑单测 + 删除项回归断言 |

**明确不做**:不接入 CI 自动再生(用户选择手动维护目录);不保留任何国内节点 / 青毅云推广;不改 `run_iperf_once` 的 iperf3 调用本身。

## 3. 数据文件 `utils/iperf3_servers.txt` 新结构

**格式保持与现状完全一致**(便于平滑迁移):

```text
#GROUP:亚太
<host>|<端口或范围>|<运营商>|<城市, 国 (带宽)>|IPv4|IPv6
...
#GROUP:欧洲
...
#GROUP:北美
...
#GROUP:南美
...
#GROUP:大洋洲
...
#GROUP:非洲
...
```

- 字段:`host|端口(单端口或 `5201-5210` 范围)|运营商|位置串|IPv4[|IPv6]`。`IPv6` 标记**仅在服务器确实支持时**写。
- **数据文件分组名保持中文**(用于报告 `###` 子标题的可读显示);CLI 用统一的大洲码,二者间由映射表连接(见 §5)。
- **组内顺序 = 优先级**:最可靠 / 带宽最高 / 支持 IPv6 / 多端口的排前面,使「默认前 N 个」挑到的就是最优的。
- **保留现有全部国际节点**,只是重新归区(维也纳→欧洲、圣保罗→南美、新加坡/塔什干→亚太、伦敦/阿姆斯特丹→欧洲、堪萨斯城/洛杉矶/纽约→北美)。
- **删除** `#GROUP:国内节点` 段及 `14.119.118.214`、`36.150.232.152` 两个青毅云节点。

**Curation 目标节点数**(目标值,实际受公共 iperf3 可用性约束;够不到 N 时该组就少于 N,选择逻辑自然兼容):

| 地区(CLI 码) | 目标量 | 重点城市(示例) |
| :--- | :--- | :--- |
| 亚太 `AS`(优先) | ~10–15 | 香港、东京、大阪、新加坡、首尔、台北、孟买、曼谷、吉隆坡、雅加达、胡志明、塔什干 |
| 欧洲 `EU` | ~6–10 | 伦敦、阿姆斯特丹、法兰克福、巴黎、维也纳、华沙、米兰、斯德哥尔摩、马德里 |
| 北美 `NA` | ~6–10 | 洛杉矶、纽约、堪萨斯城、芝加哥、达拉斯、西雅图、迈阿密、多伦多 |
| 南美 `SA` | 尽力 ~5 | 圣保罗、布宜诺斯艾利斯、圣地亚哥、波哥大、利马 |
| 大洋洲 `OC` | 尽力 ~5 | 悉尼、墨尔本、珀斯、奥克兰 |
| 非洲 `AF` | 尽力 | 约翰内斯堡、开普敦、内罗毕、拉各斯、开罗 |

**来源**:现有节点 + 社区维护的公共列表(如 `github.com/R0GGER/public-iperf3-servers`)+ 各大机房已知公开端点。无法从开发环境逐个 live 压测,按已知良好来源筛选并保守排序;**某重点城市无公开 iperf3 时,记录该缺口而非留空凑数**。

## 4. 解析器 `get_iperf3_servers` 重写

没有国内组后,**所有 `#GROUP:` 都是同一种「国际式」测试**,解析器不再区分行为。

- **沿用本仓库已有惯用法**(`trace_targets`/`forward_sources`,见 `linux_bench.sh:2805+`):把 `#GROUP:<地区>` 标记行与节点行**一起按文件顺序**存进单个扁平数组 `locs`。
- 删除 `locs_cn`(及 `run_iperf_test` 里的 `local locs_cn=()`)。
- 空行 / 非 `#GROUP:` 的注释行照常跳过;`#GROUP:` 行作为标记元素入数组。
- 下载失败:沿用现有 `retry_download` 失败 → `warn` 返回的逻辑,不变。

## 5. 选择逻辑(纯函数,可单测)与 CLI 语义

把「挑哪些节点」与「跑 iperf」**分离**:新增纯函数 `iperf_build_plan`,输入 = 解析后的 `locs` + 控制变量,输出 = 选中的 `<地区>|<原始节点行>` 有序列表(逐行 echo 到 stdout),**不碰网络、不改全局**。`run_iperf_test` 消费它的输出去执行。这样选择逻辑可喂夹具做单测,无需真实 iperf。

**统一地区编码(CLI token ↔ 数据文件组名)** —— 两字母大洲码,**规范形大写,解析大小写不敏感**:

| CLI 码 | 组名 |
| :-- | :-- |
| `AS` | 亚太 |
| `EU` | 欧洲 |
| `NA` | 北美 |
| `SA` | 南美 |
| `OC` | 大洋洲 |
| `AF` | 非洲 |

**每地区「有效上限」规则**:
- **亚太(优先区,= `IPERF_PRIORITY_GROUP`)**:默认上限 = **不限(全测)**,且**不受 `--iperf-per-region` 影响**(保「默认亚太全测」)。
- **其他 5 区**:默认上限 = **`IPERF_DEFAULT_PER_REGION` = 5**。
- `--iperf-all` 置位:运行集内**所有**区上限 = 不限。

**运行集(哪些区会跑)规则**:
- 默认:`{亚太}`。
- `--iperf-region=<codes>`:**替换**为这些区(逗号分隔,用上表大洲码)。
- `--iperf-all` 且**未**带 `--iperf-region`:运行集扩为全 6 区。

**组合语义(N=5)**:

| 命令 | 跑哪些区 | 亚太 | 其他区 |
| :--- | :--- | :--- | :--- |
| (无) | 亚太 | 全测 | — |
| `--iperf-region=EU,NA` | 欧洲+北美 | — | 各前 5 |
| `--iperf-region=AS,EU` | 亚太+欧洲 | 全测 | 欧洲前 5 |
| `--iperf-per-region=4 --iperf-region=EU` | 欧洲 | — | 前 4 |
| `--iperf-all` | 全 6 区 | 全测 | 全测 |
| `--iperf-all --iperf-region=EU,NA` | 欧洲+北美 | — | 全测 |

- 「前 N」= 取该组文件内的前 N 行(组内顺序即优先级)。`N > 组内节点数` → 取全部。
- `--iperf-all` 优先于 `--iperf-per-region`(前者=不限)。
- `--skip-iperf`、`-4/-6` 行为不变(仍逐节点按 `HAS_V4/V6` 与 `modes` 字段过滤 IP 版本)。

## 6. CLI 参数解析集成(`parse_args`)

在现有单 `shift` 的 `case` 循环中新增(带值选项用 `--opt=value` 形式以贴合循环):

```sh
--iperf-all)            IPERF_ALL=true ;;
--iperf-region=*)       IPERF_REGION="${1#*=}" ;;
--iperf-per-region=*)   IPERF_PER_REGION="${1#*=}" ;;
```

**校验**(沿用脚本的硬 `fail` 风格):
- `--iperf-per-region` 值非正整数(`^[1-9][0-9]*$` 不匹配)→ `fail "…--iperf-per-region 需为正整数…"; exit 1`。
- `--iperf-region` 含未知码 → `fail "未知 --iperf-region 地区: 'xxx'。可选: AS,EU,NA,SA,OC,AF。"; exit 1`(与脚本「未知选项硬失败」一致,避免拼错被静默忽略)。
- 码大小写归一(统一为大写)、去重。

## 7. 顶部配置常量与默认值

在 `linux_bench.sh` 顶部「运行开关」区集中定义,避免魔法字符串、便于测试:

```sh
IPERF_PRIORITY_GROUP="亚太"      # 默认全测、且不受 per-region 上限约束的优先区
IPERF_DEFAULT_PER_REGION=5       # 非优先区默认每区上限
IPERF_ALL=false                  # --iperf-all
IPERF_REGION=""                  # --iperf-region=<codes>(空=默认运行集)
IPERF_PER_REGION=""              # --iperf-per-region=<N>(空=用默认 5)
```

地区码 ↔ 组名映射也集中为一处常量(如 case 或关联数组),供 `parse_args` 校验与 `iperf_build_plan` 共用。

## 8. 执行与报告(`run_iperf_test`)

- 删除 `locs_cn` 声明、整段国内测试循环(`linux_bench.sh:1725-1761`)及青毅云推广块(`1730-1734`)。
- 顶部仍打印一次 `## 网络带宽测试`。
- 遍历 `iperf_build_plan` 的输出:每进入一个**新地区**时打印 `### <地区>` 子标题 + 该区表头(列同现状:`IP 类型 | 运营商 | 服务器位置 | 发送带宽 | 接收带宽 | 延迟`),随后逐节点跑现有国际式测试(v4/v6 各 send+recv + ping 延迟)并流式写行。
- 控制台树状输出按地区分段(`├─ 亚太…` / `├─ 欧洲…`),保留 `[idx/总数]` 进度。
- 空运行集 / 选中 0 节点 → 打印一条 info 说明,不产生空表头。

## 9. 错误处理与边界

- 下载失败:`get_iperf3_servers` 沿用 `retry_download` 失败 → `warn` 返回。
- 文件无任何有效组 / 解析为空 → `run_iperf_test` 给 info 并跳过。
- 某地区组在文件中存在但 0 节点 → 不打印该区子标题。
- `--iperf-region` 指定了文件中尚无节点的区(如 `AF` 暂缺)→ 该区无输出 + 一条 info,不报错(注意:这与 §6「未知码硬失败」不同——`AF` 是合法码,只是该组暂空)。
- 死/忙节点:由现有 `run_iperf_once` 的 2 次重试 + `timeout 15` + 输出 `busy` 兜底,不阻塞整轮。

## 10. 测试

- **纯逻辑单测**(bash,放 `tests/`,并入 `run_all.sh`,用现有 `assert.sh`):对 `iperf_build_plan` 喂**夹具节点列表 + 不同开关组合**,断言选中的 `<地区>|<节点>` 序列。覆盖:
  - 默认 → 仅亚太、且为全部亚太节点;
  - `--iperf-region=EU,NA` → 仅欧洲+北美、各前 5、不含亚太;
  - `--iperf-region=AS,EU` → 亚太全 + 欧洲前 5;
  - `--iperf-per-region=2` → 非亚太区前 2、亚太仍全(验证亚太不受 per-region 影响);
  - `--iperf-all` → 全 6 区全测;
  - 大小写不敏感(如 `eu` == `EU`);
  - `N > 组内节点数` → 取全部;短组(如非洲 3 个)top-5 = 3。
- **参数校验测**(扩展 `tests/test_args.sh` / `test_int_validation.sh`):非法 `--iperf-per-region`、未知 `--iperf-region` 码 → 非零退出。
- **回归断言**:脚本与 `iperf3_servers.txt` 中**不再出现**(大小写不敏感匹配) `青毅云` / `YOUTHIDC` / `IEPL` / `国内节点` / `locs_cn`(`README.md` 致谢区的 `YOUTHIDC` 不在断言范围内)。
- **手动冒烟**:在 Linux 测试机跑 `--skip-...`(仅留 iperf)各开关组合,核对默认只测亚太、`--iperf-region`/`--iperf-all`/`--iperf-per-region` 行为与报告分区正确。

## 11. 文档(`README.md`)

- 在「按需跳过功能」附近新增一小节,说明 iperf3 地区选择:列出 `--iperf-all`、`--iperf-region=<AS,EU,NA,SA,OC,AF>`、`--iperf-per-region=<N>`,给组合示例、大洲码对照表与「默认仅全测亚太」的说明。
- `--help`/`print_usage` 文本同步加这三项。
- **保留** `README.md:191` 致谢区的 `YOUTHIDC` 链接。

## 12. 范围外(本次不做)

- 不接入 CI / Globalping 等自动再生目录(目录手动维护)。
- 不保留任何国内节点与青毅云推广。
- 不做随机抽样模式、不改 `run_iperf_once` 的 iperf3 调用与计时。
- 不改回程/去程追踪、Cloudflare/Apple 测速等其它模块。
