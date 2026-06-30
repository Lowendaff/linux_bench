# 去程源 Globalping CI 再生 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 CI 定期从 Globalping 探针数据再生 `utils/forward_sources.txt`,自动补充尽可能多的中国大陆运营商 `--from` 去程源。

**Architecture:** 纯增量、与现有 `fetch_nf_ix_map` 同构:新增一个 Python 生成器(纯函数 `build_sources` + I/O 包装 `fetch_probes`/`main`)+ 一个 GitHub Actions 工作流 + 再生的数据文件。`run_forward_trace_test` 运行时已下载解析该数据文件,**不改 `linux_bench.sh`**。

**Tech Stack:** Python 3(仅 stdlib:`urllib`/`json`/`logging`/`os`/`sys`/`unittest`);GitHub Actions;Globalping REST API。

## Global Constraints

- **仅 Python 3 stdlib,无第三方依赖**(不引入 requests/pytest)。CI 用 Python 3.12;脚本兼容 3.x。
- **确定性输出**:分组顺序固定 `中国电信→中国联通→中国移动→中国云厂商→中国其他`,组内按 ASN 升序;**默认不写时间戳**(无数据变化时不产生 diff)。
- **失败安全**:`fetch_probes` 抛异常或生成文本中无 `CN+AS` → `sys.exit(1)`,**不覆盖** `utils/forward_sources.txt`。
- **不改 `linux_bench.sh`**。
- 数据文件 `utils/forward_sources.txt`:中国大陆分组动态生成 + 非中国分组静态尾块。
- `--from` 值格式固定 `CN+AS<asn>`。
- 工作流仿 `.github/workflows/fetch_nf_ix_map.yml`(结构同构,仅名称/路径/cron/脚本/提交信息/文件名不同)。
- Conventional Commits。

## File Structure

| 文件 | 责任 | 操作 |
| :--- | :--- | :--- |
| `utils/fetch_forward_sources.py` | 生成器:`build_sources`(纯)+ `fetch_probes`/`main`(I/O) | 新建(T1 核心逻辑,T2 加 I/O) |
| `tests/test_fetch_forward_sources.py` | stdlib unittest,测 `build_sources` | 新建(T1) |
| `utils/forward_sources.txt` | 去程源数据文件 | 由生成器再生并提交(T2) |
| `.github/workflows/fetch_forward_sources.yml` | 定时再生工作流 | 新建(T3) |

---

## Task 1: 生成器纯逻辑 `build_sources` + 单元测试(TDD)

**Files:**
- Create: `utils/fetch_forward_sources.py`(本任务只含 `build_sources` + 数据表)
- Create: `tests/test_fetch_forward_sources.py`

**Interfaces:**
- Produces: `build_sources(probes: list) -> str` —— 纯函数,输入 Globalping 探针列表(每个 `{"location": {"country","asn","city","network",...}}`),返回完整 `forward_sources.txt` 文本。规则:只取 `country=="CN"` 且 `asn` 为 int 的探针,按 ASN 去重;已知 ASN 用 `ASN_INFO` 的(分组,名),未知 ASN 进 `中国其他`、名 `"{城市} (AS{asn})"`(城市取该 ASN 探针中字母序最前的非空城市,无则 `?`);组按 `GROUP_ORDER`、组内 ASN 升序;尾部附 `STATIC_TAIL`;无 CN 条目时文本里不含 `CN+AS`(供 `main` 判退)。
- Produces: 模块级常量 `ASN_INFO`(dict)、`GROUP_ORDER`(list)、`HEADER`、`STATIC_TAIL`。

- [ ] **Step 1: 写失败测试 `tests/test_fetch_forward_sources.py`**

```python
import os
import random
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "utils"))
from fetch_forward_sources import build_sources


def probe(country, asn, city="", network=""):
    return {"location": {"country": country, "asn": asn, "city": city, "network": network}}


FIXTURE = [
    probe("CN", 4134, "Shenzhen", "Chinanet Backbone"),
    probe("CN", 4134, "Guangzhou", "Chinanet"),       # 同 ASN 第二探针 -> 去重
    probe("CN", 9808, "Beijing", "China Mobile"),
    probe("CN", 45090, "Shenzhen", "Tencent"),
    probe("CN", 136188, "Ningbo", "NINGBO ZHEJIANG"),  # 未知 -> 中国其他 自动命名
    probe("US", 174, "New York", "Cogent"),            # 非 CN -> 不进动态分组
    probe("CN", None, "X", "weird"),                   # 无效 asn -> 跳过
]


class TestBuildSources(unittest.TestCase):
    def setUp(self):
        self.text = build_sources(FIXTURE)

    def test_known_asn_named_and_grouped(self):
        self.assertIn("中国电信 163|CN+AS4134", self.text)
        self.assertIn("中国移动 CMNET|CN+AS9808", self.text)
        self.assertIn("腾讯云|CN+AS45090", self.text)

    def test_unknown_asn_auto_named_in_other(self):
        self.assertIn("Ningbo (AS136188)|CN+AS136188", self.text)
        self.assertIn("#GROUP:中国其他", self.text)

    def test_dedup_by_asn(self):
        self.assertEqual(self.text.count("CN+AS4134"), 1)

    def test_only_valid_cn_dynamic_entries(self):
        # 去重且有效的 CN ASN: 4134, 9808, 45090, 136188 = 4
        self.assertEqual(self.text.count("CN+AS"), 4)

    def test_known_asn_without_probe_absent(self):
        # AS4809(CN2) 在 ASN_INFO 但夹具无探针 -> 不出现
        self.assertNotIn("CN+AS4809", self.text)

    def test_group_order(self):
        i_tel = self.text.index("#GROUP:中国电信")
        i_cloud = self.text.index("#GROUP:中国云厂商")
        i_other = self.text.index("#GROUP:中国其他")
        self.assertTrue(i_tel < i_cloud < i_other)

    def test_static_tail_present(self):
        self.assertIn("#GROUP:亚太地区", self.text)
        self.assertIn("香港 PCCW|HK+AS3491", self.text)
        self.assertIn("美国 Cogent|US+AS174", self.text)

    def test_empty_cn_has_no_dynamic_but_keeps_tail(self):
        t = build_sources([probe("US", 174, "NYC", "Cogent")])
        self.assertNotIn("CN+AS", t)         # main 据此 exit 1
        self.assertIn("#GROUP:亚太地区", t)   # 静态尾块仍在

    def test_deterministic_regardless_of_input_order(self):
        shuffled = FIXTURE[:]
        random.shuffle(shuffled)
        self.assertEqual(build_sources(shuffled), self.text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
```

- [ ] **Step 2: 运行测试,确认失败**

Run: `python3 tests/test_fetch_forward_sources.py`
Expected: `ModuleNotFoundError: No module named 'fetch_forward_sources'`(文件还没建)。

- [ ] **Step 3: 实现 `utils/fetch_forward_sources.py`(本任务只到 build_sources + 数据表)**

```python
#!/usr/bin/env python3
"""从 Globalping 探针数据生成去程追踪源列表 utils/forward_sources.txt。

中国大陆分组按 ASN 自动生成(只含当前有探针的 ASN);非中国分组为静态维护。
"""
import json
import logging
import os
import sys
import urllib.request

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)

OUTPUT_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "forward_sources.txt")
PROBES_URL = "https://api.globalping.io/v1/probes"

# 已知中国大陆 ASN -> (分组, 显示名)
ASN_INFO = {
    4134:   ("中国电信", "中国电信 163"),
    4809:   ("中国电信", "中国电信 CN2"),
    4847:   ("中国电信", "中国电信 AS4847"),
    151185: ("中国电信", "中国电信 (武汉)"),
    4837:   ("中国联通", "中国联通 169"),
    9929:   ("中国联通", "中国联通 A网 (9929)"),
    4808:   ("中国联通", "中国联通 (北京)"),
    17621:  ("中国联通", "中国联通 (上海)"),
    9808:   ("中国移动", "中国移动 CMNET"),
    58807:  ("中国移动", "中国移动 CMIN2"),
    56048:  ("中国移动", "中国移动 (北京)"),
    24400:  ("中国移动", "中国移动 (上海)"),
    24445:  ("中国移动", "中国移动 (河南)"),
    56046:  ("中国移动", "中国移动 (扬州)"),
    56047:  ("中国移动", "中国移动 (长沙)"),
    45090:  ("中国云厂商", "腾讯云"),
    37963:  ("中国云厂商", "阿里云"),
    55990:  ("中国云厂商", "华为云"),
    17962:  ("中国其他", "深圳天威 (Topway)"),
}
GROUP_ORDER = ["中国电信", "中国联通", "中国移动", "中国云厂商", "中国其他"]
OTHER_GROUP = "中国其他"

HEADER = (
    "# 去程路由追踪源列表 (Forward Trace Sources)\n"
    "# 格式: 显示名称|--from参数\n"
    "# 每行一个源，#开头的行为注释或分组标记\n"
    "# #GROUP:分组名 用于在报告中分组显示\n"
    "# 中国大陆分组由 utils/fetch_forward_sources.py 从 Globalping 探针自动生成；非中国分组为静态维护。\n"
)

STATIC_TAIL = """#GROUP:亚太地区
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
"""


def build_sources(probes):
    """纯函数:输入 Globalping 探针列表,返回 forward_sources.txt 完整文本。"""
    cities_by_asn = {}
    for p in probes:
        loc = p.get("location") or {}
        if loc.get("country") != "CN":
            continue
        asn = loc.get("asn")
        if not isinstance(asn, int):
            continue
        cities_by_asn.setdefault(asn, []).append(loc.get("city") or "")

    grouped = {g: [] for g in GROUP_ORDER}
    for asn in sorted(cities_by_asn):
        if asn in ASN_INFO:
            group, name = ASN_INFO[asn]
        else:
            cities = sorted(c for c in set(cities_by_asn[asn]) if c)
            city = cities[0] if cities else "?"
            group, name = OTHER_GROUP, "{} (AS{})".format(city, asn)
        grouped[group].append((asn, name))

    parts = [HEADER]
    for group in GROUP_ORDER:
        if not grouped[group]:
            continue
        parts.append("\n#GROUP:{}\n".format(group))
        for asn, name in grouped[group]:
            parts.append("{}|CN+AS{}\n".format(name, asn))
    parts.append("\n" + STATIC_TAIL)
    return "".join(parts)
```

- [ ] **Step 4: 运行测试,确认通过**

Run: `python3 tests/test_fetch_forward_sources.py`
Expected: `Ran 9 tests` … `OK`。

- [ ] **Step 5: 提交**

```bash
git add utils/fetch_forward_sources.py tests/test_fetch_forward_sources.py
git commit -m "feat: build_sources generator for forward trace sources (tested)"
```

---

## Task 2: I/O 包装 `fetch_probes`/`main` + 再生 `forward_sources.txt`

**Files:**
- Modify: `utils/fetch_forward_sources.py`(在 `build_sources` 之后追加 `fetch_probes`/`main` + `__main__` 守卫)
- Create(由脚本生成): `utils/forward_sources.txt`(覆盖现有)

**Interfaces:**
- Consumes: `build_sources`(T1)
- Produces: `fetch_probes() -> list`(GET `PROBES_URL`,30s 超时,带 UA 头,返回解析后的 JSON 列表;失败抛异常);`main()`(fetch→build→若文本无 `CN+AS` 则 `sys.exit(1)` 否则写 `OUTPUT_FILE`)。

- [ ] **Step 1: 追加 `fetch_probes`/`main` 到 `utils/fetch_forward_sources.py` 末尾**

```python
def fetch_probes():
    req = urllib.request.Request(
        PROBES_URL, headers={"User-Agent": "linux_bench-forward-sources/1.0"}
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def main():
    try:
        probes = fetch_probes()
    except Exception as e:
        logging.error("获取 Globalping 探针失败: %s", e)
        sys.exit(1)
    text = build_sources(probes)
    if "CN+AS" not in text:
        logging.error("未获取到任何中国大陆探针,放弃覆盖 forward_sources.txt")
        sys.exit(1)
    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        f.write(text)
    logging.info("已生成 %s(中国大陆源 %d 条)", OUTPUT_FILE, text.count("CN+AS"))


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: 单元测试仍通过(确认追加 I/O 没破坏纯逻辑)**

Run: `python3 tests/test_fetch_forward_sources.py`
Expected: `Ran 9 tests` … `OK`(导入模块不会跑 `main`,因有 `__main__` 守卫)。

- [ ] **Step 3: 联网运行生成器,再生 `utils/forward_sources.txt`**

Run: `python3 utils/fetch_forward_sources.py`
Expected: 末尾日志 `已生成 .../forward_sources.txt(中国大陆源 N 条)`,N 约 15-20。

- [ ] **Step 4: 人工核对 + 格式自检**

Run:
```bash
echo "=== 中国大陆动态分组预览 ===" && sed -n '/#GROUP:中国/,/#GROUP:亚太/p' utils/forward_sources.txt
echo "=== 每行格式都是 名|XX+ASNNN 或 #注释/分组? (异常行应为空) ===" && grep -vE '^#|^$|^[^|]+\|[A-Z]{2}\+AS[0-9]+$' utils/forward_sources.txt || echo "格式 OK ✓"
echo "=== 静态尾块仍在? ===" && grep -q '香港 PCCW|HK+AS3491' utils/forward_sources.txt && echo "✓"
```
Expected:动态分组含 电信/联通/移动/云厂商(可能含其他);格式自检无异常行;静态尾块在。

- [ ] **Step 5: 提交**

```bash
git add utils/fetch_forward_sources.py utils/forward_sources.txt
git commit -m "feat: fetch Globalping probes and regenerate forward_sources.txt"
```

---

## Task 3: GitHub Actions 工作流

**Files:**
- Create: `.github/workflows/fetch_forward_sources.yml`

**Interfaces:** 无代码接口;仿 `.github/workflows/fetch_nf_ix_map.yml` 结构。

- [ ] **Step 1: 写工作流文件**

```yaml
name: Fetch Forward Trace Sources

on:
  workflow_dispatch:
  push:
    branches:
      - main
    paths:
      - ".github/workflows/fetch_forward_sources.yml"
      - "utils/fetch_forward_sources.py"
  schedule:
    # 每周一 UTC 01:00 (错开 nf_ix_map 的 00:00)
    - cron: "0 1 * * 1"

permissions:
  contents: write

concurrency:
  group: forward-sources-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: false

jobs:
  fetch:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.12"

      - name: Fetch forward trace sources
        run: python utils/fetch_forward_sources.py

      - name: Commit and push changes
        run: |
          git config --local user.name "github-actions[bot]"
          git config --local user.email "41898282+github-actions[bot]@users.noreply.github.com"
          if git status --porcelain utils/forward_sources.txt | grep -q .; then
            git add utils/forward_sources.txt
            git commit -m 'actions: Update forward trace sources'
            git pull --rebase origin main
            git push origin HEAD:main
          else
            echo 'No changes to commit'
          fi
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

- [ ] **Step 2: 结构自检(与已验证的 nf_ix_map 工作流对比)**

Run:
```bash
echo "=== 与 nf_ix_map 工作流的差异(应只在 名称/concurrency/paths/cron/脚本/提交信息/文件名)===" 
diff .github/workflows/fetch_nf_ix_map.yml .github/workflows/fetch_forward_sources.yml
echo "=== YAML 可解析? (有 pyyaml 才校验) ===" 
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/fetch_forward_sources.yml')); print('YAML OK')" 2>/dev/null || echo "(本机无 pyyaml,跳过;结构已与 nf_ix_map 对齐)"
```
Expected:diff 只落在预期字段;YAML 可解析(或本机无 pyyaml 时跳过)。

- [ ] **Step 3: 提交**

```bash
git add .github/workflows/fetch_forward_sources.yml
git commit -m "ci: weekly workflow to regenerate forward trace sources from Globalping"
```

---

## Task 4: 测试机去程冒烟验证(无新提交)

**Files:** 无(验证)。在 45.146.243.36 上验证再生后的源确实能用。

**Interfaces:** 消费 T2 产出的 `utils/forward_sources.txt`。

- [ ] **Step 1: 把再生后的 forward_sources.txt 送上测试机并取 nexttrace**

Run:
```bash
ssh -o BatchMode=yes root@45.146.243.36 'rm -rf /root/fwd-test && mkdir -p /root/fwd-test'
scp -q utils/forward_sources.txt root@45.146.243.36:/root/fwd-test/
ssh -o BatchMode=yes root@45.146.243.36 'cd /root/fwd-test && curl -fsSL -o nt https://github.com/nxtrace/NTrace-core/releases/latest/download/nexttrace_linux_amd64 && chmod +x nt && echo nexttrace-ready'
```
Expected: `nexttrace-ready`。

- [ ] **Step 2: 对每个中国大陆源跑 `--from`,统计成功率**

Run:
```bash
ssh -o BatchMode=yes root@45.146.243.36 'cd /root/fwd-test
MYIP=$(curl -s4 --max-time 5 https://api.ipify.org)
ok=0; fail=0
grep -E "\|CN\+AS" forward_sources.txt | while IFS="|" read -r name param; do
  out=$(timeout 40 ./nt --json --from "$param" "$MYIP" 2>/dev/null | sed "s/^[^{]*//")
  if echo "$out" | head -c1 | grep -q "{"; then echo "OK   $name ($param)"; else echo "FAIL $name ($param)"; fi
done'
```
Expected:多数 `CN+ASxxxx` 源返回 `OK`(JSON 路由);少量 `FAIL`(探针此刻离线)是预期的、可接受的。

- [ ] **Step 3: 清理测试机**

Run: `ssh -o BatchMode=yes root@45.146.243.36 'rm -rf /root/fwd-test'`
Expected:无输出。

---

## 自检备注(已对照 spec)

- **覆盖**:生成器纯逻辑+测试→T1;I/O+再生数据→T2;CI→T3;真机冒烟→T4。§5 静态尾块在 `STATIC_TAIL`(T1);§7 确定性/不写时间戳在 build_sources(T1,无时间戳输出);失败安全在 main(T2)。
- **类型一致**:`build_sources(probes)->str`、`fetch_probes()->list`、`main()`、`ASN_INFO`/`GROUP_ORDER`/`STATIC_TAIL`/`OUTPUT_FILE`/`PROBES_URL` 跨任务一致。
- **占位**:无 TODO/TBD;ASN_INFO、STATIC_TAIL、workflow 均为完整内容;真实探针数据由 T2 联网生成(环境事实,非占位)。
