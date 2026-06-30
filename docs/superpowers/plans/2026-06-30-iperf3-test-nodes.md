# 可扩展的 iperf3 测试节点 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 iperf3 带宽测试从「硬编码两组、每次全测」升级为「6 个地区分组的丰富目录 + 运行时按地区/数量选择」,并删除已失效的国内组与脚本内青毅云推广。

**Architecture:** 三层分离 —— `get_iperf3_servers`(只负责下载,隔离网络)→ `iperf_build_plan`(纯函数:读服务器列表 stdin + 读 `IPERF_*` 全局开关 → 输出选中的 `组名<TAB>节点行`,可单测、不碰网络)→ `run_iperf_test`(消费计划、按地区打印 `###` 子标题并跑现有国际式 iperf 测试)。CLI 用统一两字母大洲码 `AS/EU/NA/SA/OC/AF`,经一处映射函数 `iperf_region_to_group` 转中文组名。

**Tech Stack:** Bash(主脚本 `linux_bench.sh`)、纯 Bash 断言库 `tests/assert.sh`(sourced-in-subshell 测试模式)、数据文件 `utils/iperf3_servers.txt`。

## Global Constraints

- **可移植 Bash**:测试可能在 macOS 自带 bash 3.2 跑。**禁用 bash-4-only 特性**:不用 `${x^^}`、不用关联数组(`declare -A`)。大小写折叠用 `tr '[:lower:]' '[:upper:]'`;逗号拆分用 `IFS=',' read -ra`。
- **数据文件格式**(保持与现状一致):`host|端口或范围|运营商|位置串|IPv4[|IPv6]`;分组标记 `#GROUP:<中文地区>`;`#` 开头为注释。`IPv6` 标记仅在服务器确实支持时写。
- **统一地区编码**:CLI 码 `AS=亚太, EU=欧洲, NA=北美, SA=南美, OC=大洋洲, AF=非洲`;规范形大写,解析大小写不敏感;未知码硬失败(`exit 1`)。
- **优先区 = 亚太**:默认运行集 = `{亚太}`;亚太默认全测,且**不受 `--iperf-per-region` 约束**。
- **默认非优先区上限 N = 5**。`--iperf-all` = 运行集内所有区全测(无上限),且不带 `--iperf-region` 时运行集扩为全 6 区。
- **删除**:脚本内青毅云推广块 + 国内测试逻辑 + `locs_cn`;数据文件国内组与两个青毅云节点。**保留** `README.md` 致谢区的 `YOUTHIDC` 链接。
- **不做**:CI 自动再生(目录手动维护)、随机抽样、改 `run_iperf_once` 的 iperf3 调用与计时。
- **测试约定**:新测试文件放 `tests/`,命名 `test_*.sh`(被 `run_all.sh` 自动发现);`source assert.sh`;在子 shell 内 `source "$LB"` 后再设 `IPERF_*` 变量(源码顶部赋值会重置默认,故覆盖必须在 source 之后)。

**关键锚点(当前行号,实现时以内容定位为准):**
- 运行开关变量块:`linux_bench.sh:57-76`(在 `RUN_FORWARD_TRACE=true` 后新增 `IPERF_*` 块)
- `print_usage` heredoc:`linux_bench.sh:88-125`
- `parse_args` case 循环:`linux_bench.sh:128-163`(单 `shift`,未知选项硬 `fail; exit 1`)
- 校验器 `is_uint`/`is_num`:`linux_bench.sh:324-325`(在其后加 `iperf_region_to_group`)
- `run_iperf_once`:`linux_bench.sh:1623-1650`(**不改**)
- `get_iperf3_servers`:`linux_bench.sh:1652-1680`(整体重写)
- `run_iperf_test`:`linux_bench.sh:1682-1766`(整体重写,删国内段+广告)
- main 启动横幅提示:`linux_bench.sh:3210-3216`
- main 守卫:`linux_bench.sh:3291`(`source` 时不跑 main,测试可安全 source)

---

### Task 1: 配置变量 + 地区码映射函数

**Files:**
- Modify: `linux_bench.sh`(运行开关块 `:71` 后新增常量;`is_num` `:325` 后新增 `iperf_region_to_group`)
- Test: `tests/test_iperf_region_map.sh`(新建)

**Interfaces:**
- Produces:
  - 全局变量 `IPERF_PRIORITY_GROUP`(默认 `亚太`)、`IPERF_DEFAULT_PER_REGION`(默认 `5`)、`IPERF_ALL`(默认 `false`)、`IPERF_REGION`(默认 `""`)、`IPERF_PER_REGION`(默认 `""`)、`IPERF_SERVERS_FILE`(默认 `""`)
  - `iperf_region_to_group <code>`:echo 中文组名;未知码 `return 1`、无输出。大小写不敏感。

- [ ] **Step 1: 写失败测试** — 新建 `tests/test_iperf_region_map.sh`:

```bash
#!/usr/bin/env bash
# 验证地区码映射(大小写不敏感)与 iperf3 选择相关默认变量。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/assert.sh"
LB="$HERE/../linux_bench.sh"

assert_eq "$( source "$LB" 2>/dev/null; iperf_region_to_group EU )" "欧洲" "EU->欧洲"
assert_eq "$( source "$LB" 2>/dev/null; iperf_region_to_group eu )" "欧洲" "eu->欧洲(小写)"
assert_eq "$( source "$LB" 2>/dev/null; iperf_region_to_group AS )" "亚太" "AS->亚太"
assert_eq "$( source "$LB" 2>/dev/null; iperf_region_to_group NA )" "北美" "NA->北美"
assert_eq "$( source "$LB" 2>/dev/null; iperf_region_to_group SA )" "南美" "SA->南美"
assert_eq "$( source "$LB" 2>/dev/null; iperf_region_to_group OC )" "大洋洲" "OC->大洋洲"
assert_eq "$( source "$LB" 2>/dev/null; iperf_region_to_group AF )" "非洲" "AF->非洲"
assert_fail bash -c "source '$LB' 2>/dev/null; iperf_region_to_group XX"

assert_eq "$( source "$LB" 2>/dev/null; echo "$IPERF_PRIORITY_GROUP" )"   "亚太"  "默认优先区=亚太"
assert_eq "$( source "$LB" 2>/dev/null; echo "$IPERF_DEFAULT_PER_REGION" )" "5"   "默认 N=5"
assert_eq "$( source "$LB" 2>/dev/null; echo "$IPERF_ALL" )"               "false" "默认 IPERF_ALL=false"
assert_eq "$( source "$LB" 2>/dev/null; echo "$IPERF_REGION" )"            ""      "默认 IPERF_REGION 空"

finish
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash tests/test_iperf_region_map.sh`
Expected: FAIL —— `iperf_region_to_group` 未定义、`IPERF_*` 变量为空。

- [ ] **Step 3: 加配置变量** — 在 `linux_bench.sh` 的 `RUN_FORWARD_TRACE=true  # 去程路由追踪` 这一行**之后**插入:

```bash

# iperf3 地区选择(详见 --help / parse_args / iperf_build_plan)
IPERF_PRIORITY_GROUP="亚太"   # 优先区:默认全测,且不受 --iperf-per-region 约束
IPERF_DEFAULT_PER_REGION=5    # 非优先区默认每区上限
IPERF_ALL=false               # --iperf-all:运行集内所有区全测
IPERF_REGION=""               # --iperf-region=<AS,EU,NA,SA,OC,AF>(空=默认仅亚太)
IPERF_PER_REGION=""           # --iperf-per-region=<N>(空=用默认上限)
IPERF_SERVERS_FILE=""         # get_iperf3_servers 下载后填充的本地路径
```

- [ ] **Step 4: 加映射函数** — 在 `is_num()  { ... }` 这一行**之后**插入:

```bash
# 地区码 -> 中文组名(大小写不敏感);未知码 return 1。用 tr 折叠大小写以兼容 bash 3.2。
iperf_region_to_group() {
    local code
    code=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
    case "$code" in
        AS) echo "亚太" ;;
        EU) echo "欧洲" ;;
        NA) echo "北美" ;;
        SA) echo "南美" ;;
        OC) echo "大洋洲" ;;
        AF) echo "非洲" ;;
        *)  return 1 ;;
    esac
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `bash tests/test_iperf_region_map.sh`
Expected: PASS —— `... run, 0 failed`。

- [ ] **Step 6: 提交**

```bash
git add linux_bench.sh tests/test_iperf_region_map.sh
git commit -m "feat(iperf): add region-code config vars and code->group mapping"
```

---

### Task 2: parse_args 新增三个开关 + 校验

**Files:**
- Modify: `linux_bench.sh` · `parse_args`(`:150` `--fix-dns` 行后加三个 case 分支)
- Test: `tests/test_args.sh`(在 `finish` 前追加断言)

**Interfaces:**
- Consumes: `iperf_region_to_group`、`is_uint`(Task 1 / 现有)
- Produces: `parse_args` 识别 `--iperf-all` / `--iperf-region=<codes>` / `--iperf-per-region=<N>`,分别写 `IPERF_ALL=true` / `IPERF_REGION` / `IPERF_PER_REGION`;非法值 `fail; exit 1`。

- [ ] **Step 1: 写失败测试** — 在 `tests/test_args.sh` 的 `finish` 行**之前**追加:

```bash
# --- iperf3 地区选择开关 ---
assert_eq "$(val IPERF_ALL --iperf-all)"                 "true"  "--iperf-all 置 IPERF_ALL"
assert_eq "$(val IPERF_REGION --iperf-region=EU,NA)"     "EU,NA" "--iperf-region 捕获值"
assert_eq "$(val IPERF_PER_REGION --iperf-per-region=3)" "3"     "--iperf-per-region 捕获值"
assert_eq "$(val IPERF_ALL)"        "false" "默认 IPERF_ALL=false"
assert_eq "$(val IPERF_REGION)"     ""      "默认 IPERF_REGION 空"

# 合法:小写码、组合
assert_success bash -c "source '$LB' 2>/dev/null; parse_args --iperf-region=eu,na"
assert_success bash -c "source '$LB' 2>/dev/null; parse_args --iperf-all --iperf-region=AS"
# 非法:未知码、非正整数
assert_fail bash -c "source '$LB' 2>/dev/null; parse_args --iperf-region=XX"
assert_fail bash -c "source '$LB' 2>/dev/null; parse_args --iperf-per-region=abc"
assert_fail bash -c "source '$LB' 2>/dev/null; parse_args --iperf-per-region=0"
assert_fail bash -c "source '$LB' 2>/dev/null; parse_args --iperf-per-region=-1"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash tests/test_args.sh`
Expected: FAIL —— 新断言失败(分支未定义,`--iperf-all` 走 `*)` 未知选项分支退出 1,`val` 取不到 `true`)。

- [ ] **Step 3: 加 case 分支** — 在 `parse_args` 的 `--fix-dns)         FIX_DNS=true ;;` 行**之后**插入:

```bash
            --iperf-all)       IPERF_ALL=true ;;
            --iperf-region=*)
                IPERF_REGION="${1#*=}"
                local _codes _c
                IFS=',' read -ra _codes <<< "$IPERF_REGION"
                for _c in "${_codes[@]}"; do
                    [ -z "$_c" ] && continue
                    iperf_region_to_group "$_c" >/dev/null 2>&1 || {
                        fail "未知 --iperf-region 地区: '$_c'。可选: AS,EU,NA,SA,OC,AF。"; exit 1; }
                done
                ;;
            --iperf-per-region=*)
                IPERF_PER_REGION="${1#*=}"
                { is_uint "$IPERF_PER_REGION" && [ "$IPERF_PER_REGION" -ge 1 ]; } || {
                    fail "--iperf-per-region 需为正整数,得到 '$IPERF_PER_REGION'。"; exit 1; }
                ;;
```

- [ ] **Step 4: 跑测试确认通过**

Run: `bash tests/test_args.sh`
Expected: PASS —— `... run, 0 failed`(含原有断言 + 新增 iperf 断言)。

- [ ] **Step 5: 提交**

```bash
git add linux_bench.sh tests/test_args.sh
git commit -m "feat(iperf): parse --iperf-all/--iperf-region/--iperf-per-region with validation"
```

---

### Task 3: `iperf_build_plan` 纯选择函数

**Files:**
- Modify: `linux_bench.sh`(在 `iperf_region_to_group` 后、`get_iperf3_servers` 前新增 `iperf_build_plan`)
- Test: `tests/test_iperf_plan.sh`(新建)、`tests/fixtures/iperf_servers_sample.txt`(新建)

**Interfaces:**
- Consumes: `iperf_region_to_group`、`IPERF_*` 全局(Task 1)
- Produces: `iperf_build_plan`(从 **stdin** 读服务器列表文本;按 `IPERF_*` 选择;**逐行 echo** `组名<TAB>原始节点行`)。无网络、无全局修改。

- [ ] **Step 1: 建夹具** — 新建 `tests/fixtures/iperf_servers_sample.txt`(计数:亚太3 / 欧洲6 / 北美2 / 南美1 / 非洲7;故意无大洋洲):

```text
#GROUP:亚太
as1.example.net|5201-5210|ProvA|Hong Kong, HK (10G)|IPv4|IPv6
as2.example.net|5201|ProvB|Tokyo, JP (10G)|IPv4|IPv6
as3.example.net|5201|ProvC|Singapore, SG (1G)|IPv4
#GROUP:欧洲
eu1.example.net|5201|P|City1 (10G)|IPv4|IPv6
eu2.example.net|5201|P|City2 (10G)|IPv4|IPv6
eu3.example.net|5201|P|City3 (10G)|IPv4|IPv6
eu4.example.net|5201|P|City4 (10G)|IPv4|IPv6
eu5.example.net|5201|P|City5 (10G)|IPv4|IPv6
eu6.example.net|5201|P|City6 (10G)|IPv4|IPv6
#GROUP:北美
na1.example.net|5201|P|City1 (10G)|IPv4|IPv6
na2.example.net|5201|P|City2 (10G)|IPv4|IPv6
#GROUP:南美
sa1.example.net|5201|P|City1 (1G)|IPv4
#GROUP:非洲
af1.example.net|5201|P|C1|IPv4
af2.example.net|5201|P|C2|IPv4
af3.example.net|5201|P|C3|IPv4
af4.example.net|5201|P|C4|IPv4
af5.example.net|5201|P|C5|IPv4
af6.example.net|5201|P|C6|IPv4
af7.example.net|5201|P|C7|IPv4
```

- [ ] **Step 2: 写失败测试** — 新建 `tests/test_iperf_plan.sh`:

```bash
#!/usr/bin/env bash
# 验证 iperf_build_plan 的选择语义(纯函数,喂夹具 + 不同开关)。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/assert.sh"
LB="$HERE/../linux_bench.sh"
FIX="$HERE/fixtures/iperf_servers_sample.txt"

cnt() { printf '%s\n' "$1" | awk -F'\t' -v g="$2" 'NF>0 && $1==g' | wc -l | tr -d ' '; }
tot() { printf '%s\n' "$1" | awk -F'\t' 'NF>0'                    | wc -l | tr -d ' '; }

out=$( source "$LB" 2>/dev/null; iperf_build_plan < "$FIX" )
assert_eq "$(cnt "$out" 亚太)" "3" "默认: 亚太全部3"
assert_eq "$(tot "$out")"      "3" "默认: 仅亚太共3"

out=$( source "$LB" 2>/dev/null; IPERF_REGION="EU,NA"; iperf_build_plan < "$FIX" )
assert_eq "$(cnt "$out" 欧洲)" "5" "EU,NA: 欧洲 top5(共6)"
assert_eq "$(cnt "$out" 北美)" "2" "EU,NA: 北美全2(<5)"
assert_eq "$(cnt "$out" 亚太)" "0" "EU,NA: 不含亚太"

out=$( source "$LB" 2>/dev/null; IPERF_REGION="AS,EU"; iperf_build_plan < "$FIX" )
assert_eq "$(cnt "$out" 亚太)" "3" "AS,EU: 亚太全3"
assert_eq "$(cnt "$out" 欧洲)" "5" "AS,EU: 欧洲 top5"

out=$( source "$LB" 2>/dev/null; IPERF_REGION="AS,EU,AF"; IPERF_PER_REGION="2"; iperf_build_plan < "$FIX" )
assert_eq "$(cnt "$out" 亚太)" "3" "per-region=2: 亚太仍全3(不受影响)"
assert_eq "$(cnt "$out" 欧洲)" "2" "per-region=2: 欧洲2"
assert_eq "$(cnt "$out" 非洲)" "2" "per-region=2: 非洲2"

out=$( source "$LB" 2>/dev/null; IPERF_ALL="true"; iperf_build_plan < "$FIX" )
assert_eq "$(tot "$out")" "19" "iperf-all: 全6区全测=19"

out=$( source "$LB" 2>/dev/null; IPERF_REGION="eu"; iperf_build_plan < "$FIX" )
assert_eq "$(cnt "$out" 欧洲)" "5" "小写 eu 等同 EU"

out=$( source "$LB" 2>/dev/null; IPERF_REGION="OC"; iperf_build_plan < "$FIX" )
assert_eq "$(tot "$out")" "0" "OC 合法但样本无该组 -> 0"

finish
```

- [ ] **Step 3: 跑测试确认失败**

Run: `bash tests/test_iperf_plan.sh`
Expected: FAIL —— `iperf_build_plan` 未定义,所有计数为空。

- [ ] **Step 4: 实现 `iperf_build_plan`** — 在 `iperf_region_to_group` 函数**之后**插入:

```bash
# 纯选择函数:stdin=服务器列表文本;按 IPERF_* 开关输出选中的 "组名<TAB>节点行"。
# 规则:运行集 = IPERF_REGION 指定的区(替换默认)| IPERF_ALL 时全部出现的区 | 否则仅优先区。
# 上限   = 优先区或 IPERF_ALL -> 不限;否则 IPERF_PER_REGION(空则 IPERF_DEFAULT_PER_REGION)。
iperf_build_plan() {
    local priority="${IPERF_PRIORITY_GROUP:-亚太}"
    local default_n="${IPERF_DEFAULT_PER_REGION:-5}"
    local all="${IPERF_ALL:-false}"
    local region="${IPERF_REGION:-}"
    local per="${IPERF_PER_REGION:-}"

    # 由地区码解析显式运行集(中文组名,换行分隔,前后带换行便于整组匹配)
    local have_region=false run_set=$'\n'
    if [ -n "$region" ]; then
        have_region=true
        local _codes _c _g
        IFS=',' read -ra _codes <<< "$region"
        for _c in "${_codes[@]}"; do
            [ -z "$_c" ] && continue
            _g=$(iperf_region_to_group "$_c") || continue
            run_set="${run_set}${_g}"$'\n'
        done
    fi

    local cur="" count=0 line cap
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        if [[ "$line" == "#GROUP:"* ]]; then
            cur="${line#*#GROUP:}"
            count=0
            continue
        fi
        [[ "$line" == "#"* ]] && continue
        [ -z "$cur" ] && continue

        # 当前组是否在运行集内?
        if $have_region; then
            [[ "$run_set" == *$'\n'"$cur"$'\n'* ]] || continue
        elif [ "$all" = "true" ]; then
            :
        else
            [ "$cur" = "$priority" ] || continue
        fi

        # 该组上限(-1 = 不限)
        if [ "$cur" = "$priority" ] || [ "$all" = "true" ]; then
            cap=-1
        elif [ -n "$per" ]; then
            cap="$per"
        else
            cap="$default_n"
        fi
        if [ "$cap" -ge 0 ] && [ "$count" -ge "$cap" ]; then
            continue
        fi

        printf '%s\t%s\n' "$cur" "$line"
        count=$((count+1))
    done
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `bash tests/test_iperf_plan.sh`
Expected: PASS —— `... run, 0 failed`。

- [ ] **Step 6: 提交**

```bash
git add linux_bench.sh tests/test_iperf_plan.sh tests/fixtures/iperf_servers_sample.txt
git commit -m "feat(iperf): pure iperf_build_plan selection function with unit tests"
```

---

### Task 4: 重写 `get_iperf3_servers` + `run_iperf_test`(消费计划、删国内段与广告)

**Files:**
- Modify: `linux_bench.sh` · `get_iperf3_servers`(`:1652-1680` 整体替换)、`run_iperf_test`(`:1682-1766` 整体替换)
- Test: `tests/test_iperf_cleanup.sh`(新建)

**Interfaces:**
- Consumes: `iperf_build_plan`(Task 3)、`run_iperf_once`/`retry_download`/`check_cmd`/`HAS_V4`/`HAS_V6`(现有)、`IPERF_SERVERS_FILE`(Task 1)
- Produces: `get_iperf3_servers` 仅下载并设 `IPERF_SERVERS_FILE`(失败置空 `return 1`);`run_iperf_test` 按地区分组打印报告。无 `locs_cn`、无青毅云字样。

- [ ] **Step 1: 写失败测试** — 新建 `tests/test_iperf_cleanup.sh`:

```bash
#!/usr/bin/env bash
# 回归:脚本不再含国内推广/旧逻辑;语法合法;关键函数仍可 source。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/assert.sh"
LB="$HERE/../linux_bench.sh"

# 脚本中不应再出现这些(大小写不敏感)
for pat in 青毅云 YOUTHIDC IEPL 国内节点 locs_cn; do
    assert_fail grep -iqe "$pat" "$LB"
done

# 语法检查
assert_success bash -n "$LB"

# source 后关键函数有定义
assert_success bash -c "source '$LB' 2>/dev/null; declare -f get_iperf3_servers >/dev/null"
assert_success bash -c "source '$LB' 2>/dev/null; declare -f iperf_build_plan   >/dev/null"
assert_success bash -c "source '$LB' 2>/dev/null; declare -f run_iperf_test     >/dev/null"

finish
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash tests/test_iperf_cleanup.sh`
Expected: FAIL —— 脚本仍含 `青毅云`/`locs_cn`/`国内节点`。

- [ ] **Step 3: 替换 `get_iperf3_servers`** — 把整个 `get_iperf3_servers() { ... }`(`:1652-1680`)替换为:

```bash
get_iperf3_servers() {
    local servers_url="https://raw.githubusercontent.com/Lowendaff/linux_bench/main/utils/iperf3_servers.txt"
    IPERF_SERVERS_FILE="$TMP_DIR/iperf3_servers.txt"

    if ! retry_download "$IPERF_SERVERS_FILE" "$servers_url" "iPerf3 Servers" "--connect-timeout 5 --max-time 15"; then
        warn "  Failed to download iPerf3 servers."
        IPERF_SERVERS_FILE=""
        return 1
    fi
    return 0
}
```

- [ ] **Step 4: 替换 `run_iperf_test`** — 把整个 `run_iperf_test() { ... }`(`:1682-1766`,含国内段与青毅云广告)替换为:

```bash
run_iperf_test() {
    log "开始网络带宽测试..."
    if ! check_cmd iperf3; then warn "  └─ iperf3 未安装，跳过"; return; fi

    if ! get_iperf3_servers || [ -z "$IPERF_SERVERS_FILE" ]; then
        return
    fi

    # 纯函数选出本次要测的节点(组名<TAB>节点行)
    local plan
    plan=$(iperf_build_plan < "$IPERF_SERVERS_FILE")
    if [ -z "$plan" ]; then
        info "  └─ 无可测 iperf3 节点(检查 --iperf-region / --iperf-all 与节点列表)"
        return
    fi

    echo "## 网络带宽测试" >> "$REPORT_FILE"

    local total cur_group="" idx=0
    total=$(printf '%s\n' "$plan" | awk -F'\t' 'NF>0' | wc -l | tr -d ' ')

    while IFS=$'\t' read -r group entry; do
        [ -z "$entry" ] && continue

        if [ "$group" != "$cur_group" ]; then
            cur_group="$group"
            {
                echo ""
                echo "### $group"
                echo "| IP 类型 | 运营商 | 服务器位置 | 发送带宽 | 接收带宽 | 延迟 |"
                echo "| :--- | :--- | :--- | :--- | :--- | :--- |"
            } >> "$REPORT_FILE"
            echo "  ├─ ${group}节点测试..."
        fi

        idx=$((idx+1))
        IFS='|' read -r host ports provider loc modes <<< "$entry"
        IFS='-' read -r p0 p1 <<< "$ports"
        [ -z "$p1" ] && p1="$p0"

        for mode in IPv4 IPv6; do
            if [[ "$modes" != *"$mode"* ]]; then continue; fi
            if [ "$mode" = "IPv4" ] && [ "$HAS_V4" != "true" ]; then continue; fi
            if [ "$mode" = "IPv6" ] && [ "$HAS_V6" != "true" ]; then continue; fi
            local ipflag="-4"; [ "$mode" = "IPv6" ] && ipflag="-6"

            echo "  │  ├─ [$idx/$total] $provider - $loc ($mode)..."
            local p=$((p0 + RANDOM % (p1 - p0 + 1)))
            local send=$(run_iperf_once "$host" "$p" 8 false "$ipflag")
            p=$((p0 + RANDOM % (p1 - p0 + 1)))
            local recv=$(run_iperf_once "$host" "$p" 8 true "$ipflag")
            local lat="--"
            if [ "$mode" = "IPv4" ]; then lat=$(ping -c 1 -W 1 "$host" 2>/dev/null | grep "time=" | awk -F "time=" '{print $2}' | awk '{print $1}'); else lat=$(ping -6 -c 1 -W 1 "$host" 2>/dev/null | grep "time=" | awk -F "time=" '{print $2}' | awk '{print $1}'); fi
            echo "  │  │  └─ 发送: ${send} / 接收: ${recv} / 延迟: ${lat:---} ms"

            echo "| $mode | $provider | $loc | $send | $recv | ${lat:---} ms |" >> "$REPORT_FILE"
        done
    done <<< "$plan"

    echo "" >> "$REPORT_FILE"
    info "  └─ 带宽测试完成"
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `bash tests/test_iperf_cleanup.sh && bash tests/test_iperf_plan.sh`
Expected: 两个都 PASS。`bash -n` 通过、无残留字样、`iperf_build_plan` 测试仍绿(函数签名未变)。

- [ ] **Step 6: 提交**

```bash
git add linux_bench.sh tests/test_iperf_cleanup.sh
git commit -m "refactor(iperf): consume build_plan, per-region report sections, drop domestic+ad"
```

---

### Task 5: 数据文件 `utils/iperf3_servers.txt` 重构与节点扩充

**Files:**
- Modify: `utils/iperf3_servers.txt`(整体重写为 6 个地区分组,删国内组)
- Test: `tests/test_iperf_servers.sh`(新建)

**Interfaces:**
- Consumes: `iperf_build_plan`(Task 3)用于集成断言
- Produces: 合法的分区目录文件 —— 仅 6 个已知中文组、每行 ≥5 字段、无国内残留、默认计划仅亚太且非空。

**节点来源与排序规则**(执行者需带网络):
- **保留并重新归区现有节点**(以下为当前真实节点,直接搬运):
  - 亚太:`speedtest.sin1.sg.leaseweb.net|5201-5210|Leaseweb|Singapore, SG (10G)`、`speedtest.uztelecom.uz|5200-5209|Uztelecom|Tashkent, UZ (10G)`
  - 欧洲:`iperf3-vie-at.alwyzon.net|5201-5208|Alwyzon|Vienna, AT (100G)`、`iperf-ams-nl.eranium.net|5201-5210|Eranium|Amsterdam, NL (100G)`、`lon.speedtest.clouvider.net|5200-5209|Clouvider|London, UK (10G)`
  - 北美:`iperf-mci.advinservers.com|5201-5240|Advin Servers|Kansas City, MO (40G)`、`la.speedtest.clouvider.net|5200-5209|Clouvider|Los Angeles, CA, US (10G)`、`speedtest.nyc1.us.leaseweb.net|5201-5210|Leaseweb|NYC, NY, US (10G)`
  - 南美:`speedtest.sao1.edgoo.net|9204-9240|Edgoo|Sao Paulo, BR (1G)`
- **扩充**:从社区维护列表 `https://github.com/R0GGER/public-iperf3-servers`(及各机房公开端点)按地区补齐重点城市,目标量:亚太 ~10–15、欧洲/北美 ~6–10、南美/大洋洲/非洲 尽力 ~5。
- **筛选标准**:优先 10G+ 带宽、支持 IPv6、提供端口范围(降 busy)、列表标注 online/稳定者。**`IPv6` 标记仅在确实支持时写。**
- **组内排序 = 优先级**:最稳/带宽最高/支持 IPv6 的排前面(默认「亚太全测」与「非亚太 top-5」都取靠前者)。
- **重点城市目标**:亚太=香港/东京/大阪/新加坡/首尔/台北/孟买/曼谷/吉隆坡/雅加达/胡志明/塔什干;欧洲=伦敦/阿姆斯特丹/法兰克福/巴黎/维也纳/华沙/米兰/斯德哥尔摩/马德里;北美=洛杉矶/纽约/堪萨斯城/芝加哥/达拉斯/西雅图/迈阿密/多伦多;南美=圣保罗/布宜诺斯艾利斯/圣地亚哥/波哥大/利马;大洋洲=悉尼/墨尔本/珀斯/奥克兰;非洲=约翰内斯堡/开普敦/内罗毕/拉各斯/开罗。**某城市无公开 iperf3 时记录缺口、不留空凑数。**

- [ ] **Step 1: 写失败测试** — 新建 `tests/test_iperf_servers.sh`:

```bash
#!/usr/bin/env bash
# 校验数据文件:无国内残留、组名合法、字段数、与选择逻辑集成。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/assert.sh"
LB="$HERE/../linux_bench.sh"
SRV="$HERE/../utils/iperf3_servers.txt"

# 无国内残留
assert_fail grep -iqe 青毅云   "$SRV"
assert_fail grep -iqe 国内节点 "$SRV"

# 每个 #GROUP 必须是 6 个已知中文地区之一
bad_groups=$(grep '^#GROUP:' "$SRV" | sed 's/^#GROUP://' | grep -vxE '亚太|欧洲|北美|南美|大洋洲|非洲' || true)
assert_eq "$bad_groups" "" "所有 #GROUP 为已知地区"

# 每个节点行(非空、非 #)字段数 >=5
bad_lines=$(awk -F'|' '!/^#/ && NF>0 && NF<5 {print NR": "$0}' "$SRV")
assert_eq "$bad_lines" "" "所有节点行字段>=5"

# 至少有一个亚太节点
assert_success bash -c "grep -q '^#GROUP:亚太' '$SRV'"

# 集成:默认计划仅含亚太且非空
out=$( source "$LB" 2>/dev/null; iperf_build_plan < "$SRV" )
non_asia=$(printf '%s\n' "$out" | awk -F'\t' 'NF>0 && $1!="亚太"')
assert_eq "$non_asia" "" "默认计划仅亚太"
assert_success test -n "$out"

finish
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash tests/test_iperf_servers.sh`
Expected: FAIL —— 旧文件含 `#GROUP:国内节点` + `青毅云`,组名校验与残留校验失败。

- [ ] **Step 3: 重写数据文件** — 按上面「来源与排序规则」把 `utils/iperf3_servers.txt` 整体重写为 6 个 `#GROUP:` 地区分组(删掉 `#GROUP:国内节点` 与两个青毅云 IP 行)。最小可通过形态示意(执行者按规则补齐重点城市,真实节点须带网络核实):

```text
#GROUP:亚太
speedtest.sin1.sg.leaseweb.net|5201-5210|Leaseweb|Singapore, SG (10G)|IPv4|IPv6
speedtest.uztelecom.uz|5200-5209|Uztelecom|Tashkent, UZ (10G)|IPv4|IPv6
# ...(补:香港/东京/大阪/首尔/台北/孟买/曼谷/吉隆坡/雅加达/胡志明 等,按优先级排序)

#GROUP:欧洲
lon.speedtest.clouvider.net|5200-5209|Clouvider|London, UK (10G)|IPv4|IPv6
iperf-ams-nl.eranium.net|5201-5210|Eranium|Amsterdam, NL (100G)|IPv4|IPv6
iperf3-vie-at.alwyzon.net|5201-5208|Alwyzon|Vienna, AT (100G)|IPv4|IPv6
# ...(补:法兰克福/巴黎/华沙/米兰/斯德哥尔摩/马德里 等)

#GROUP:北美
iperf-mci.advinservers.com|5201-5240|Advin Servers|Kansas City, MO (40G)|IPv4|IPv6
la.speedtest.clouvider.net|5200-5209|Clouvider|Los Angeles, CA, US (10G)|IPv4|IPv6
speedtest.nyc1.us.leaseweb.net|5201-5210|Leaseweb|NYC, NY, US (10G)|IPv4|IPv6
# ...(补:芝加哥/达拉斯/西雅图/迈阿密/多伦多 等)

#GROUP:南美
speedtest.sao1.edgoo.net|9204-9240|Edgoo|Sao Paulo, BR (1G)|IPv4|IPv6
# ...(尽力补:布宜诺斯艾利斯/圣地亚哥/波哥大/利马)

#GROUP:大洋洲
# ...(尽力补:悉尼/墨尔本/珀斯/奥克兰)

#GROUP:非洲
# ...(尽力补:约翰内斯堡/开普敦/内罗毕/拉各斯/开罗)
```

> 注:`#GROUP:大洋洲`/`#GROUP:非洲` 即使暂无节点也可保留标题(选择逻辑对空组安全)。但**集成断言要求亚太非空**,故亚太组必须有真实节点。

- [ ] **Step 4: 跑测试确认通过**

Run: `bash tests/test_iperf_servers.sh`
Expected: PASS —— 组名合法、字段数 ≥5、无国内残留、默认计划仅亚太且非空。

- [ ] **Step 5: 全量回归 + 提交**

```bash
bash tests/run_all.sh
git add utils/iperf3_servers.txt tests/test_iperf_servers.sh
git commit -m "feat(iperf): region-grouped server catalog, drop domestic nodes"
```

---

### Task 6: 文档(`print_usage` + 启动横幅 + README)

**Files:**
- Modify: `linux_bench.sh` · `print_usage` heredoc(`:116` `--fix-dns` 行附近)、启动横幅(`:3210-3216`)
- Modify: `README.md`(「按需跳过功能」一节附近)
- Test: `tests/test_iperf_help.sh`(新建)

**Interfaces:**
- Consumes: 无(纯文档)
- Produces: `--help`、横幅、README 均含三个新开关与地区码说明。

- [ ] **Step 1: 写失败测试** — 新建 `tests/test_iperf_help.sh`:

```bash
#!/usr/bin/env bash
# --help 与 README 应包含 iperf3 地区选择开关。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/assert.sh"
LB="$HERE/../linux_bench.sh"
RM="$HERE/../README.md"

help=$( source "$LB" 2>/dev/null; print_usage )
assert_contains "$help" "--iperf-all"        "help 含 --iperf-all"
assert_contains "$help" "--iperf-region"     "help 含 --iperf-region"
assert_contains "$help" "--iperf-per-region" "help 含 --iperf-per-region"

assert_success grep -q -- "--iperf-region" "$RM"
assert_success grep -q -- "--iperf-all"    "$RM"
# README 仍保留 YOUTHIDC 致谢(仅删脚本内推广)
assert_success grep -qi "YOUTHIDC" "$RM"

finish
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash tests/test_iperf_help.sh`
Expected: FAIL —— help/README 尚无新开关。

- [ ] **Step 3: 更新 `print_usage`** — 在 heredoc 的 `  --fix-dns            测试期间临时覆盖系统 DNS` 行**之后**插入:

```text
  --iperf-all          iperf3: 全部 6 个地区全测(默认仅全测亚太)
  --iperf-region=<码>  iperf3: 只测指定地区,逗号分隔。码: AS 亚太/EU 欧洲/NA 北美/SA 南美/OC 大洋洲/AF 非洲
  --iperf-per-region=N iperf3: 非亚太地区每区最多测 N 个(默认 5;亚太恒为全测)
```

- [ ] **Step 4: 更新启动横幅** — 在 `linux_bench.sh` 的 `echo -e "  -4 / -6              仅 IPv4 / 仅 IPv6"`(`:3214`)行**之后**插入:

```bash
    echo -e "      --iperf-region=EU,NA  iperf3 只测指定地区(默认仅亚太);--iperf-all 全测"
```

- [ ] **Step 5: 更新 README** — 在 `README.md` 「按需跳过功能(`--skip-xxx`)」小节的表格**之后**(`--skip-speedtest` 行所在表格下方),新增一小节:

````markdown
### iperf3 地区选择

iperf3 节点按地区分组(数据见 `utils/iperf3_servers.txt`)。**默认只全测「亚太」**,其余地区按需开启。

| 地区码 | 地区 |
| :-- | :-- |
| `AS` | 亚太(优先,默认全测) |
| `EU` | 欧洲 |
| `NA` | 北美 |
| `SA` | 南美 |
| `OC` | 大洋洲 |
| `AF` | 非洲 |

| 开关 | 作用 |
| :--- | :--- |
| `--iperf-all` | 全部 6 个地区全测 |
| `--iperf-region=<码,...>` | 只测指定地区(替换默认;码大小写不敏感) |
| `--iperf-per-region=<N>` | 非亚太地区每区最多 N 个(默认 5;亚太恒为全测,不受此约束) |

```bash
sudo ./linux_bench.sh                              # 仅亚太全测(默认)
sudo ./linux_bench.sh --iperf-region=EU,NA         # 仅欧洲+北美,各前 5
sudo ./linux_bench.sh --iperf-region=AS,EU         # 亚太全 + 欧洲前 5
sudo ./linux_bench.sh --iperf-all                  # 全 6 区全测(很慢)
```
````

- [ ] **Step 6: 跑测试确认通过**

Run: `bash tests/test_iperf_help.sh`
Expected: PASS。

- [ ] **Step 7: 全量回归 + 提交**

```bash
bash tests/run_all.sh
git add linux_bench.sh README.md tests/test_iperf_help.sh
git commit -m "docs(iperf): document --iperf-all/--iperf-region/--iperf-per-region"
```

---

## 手动冒烟(全部 Task 完成后,在 Linux 测试机带网络执行)

```bash
sudo ./linux_bench.sh --skip-hardware --skip-trace --skip-forward --skip-cloudflare --skip-apple   # 仅 iperf:默认应只测亚太
sudo ./linux_bench.sh --skip-hardware ... --iperf-region=EU,NA       # 应只出欧洲+北美各≤5
sudo ./linux_bench.sh --skip-hardware ... --iperf-per-region=2 --iperf-region=AS,EU   # 亚太全 + 欧洲2
sudo ./linux_bench.sh ... --iperf-all                                # 全 6 区(确认报告分区 ### 标题正确)
```
核对:报告 `## 网络带宽测试` 下按 `### 亚太/欧洲/...` 分区;无国内段、无青毅云推广;死/忙节点显示 `busy`/`--` 不卡死整轮。

## Self-Review(写完即查,发现即改)

**Spec 覆盖**:
- §2 改动总览 → Task 1(常量)/2(parse_args)/3(build_plan)/4(get_iperf3_servers+run_iperf_test)/5(数据文件)/6(README+help)逐条对应 ✓
- §3 数据文件新结构 → Task 5 ✓;§4 解析器(扁平按组)→ 实现细化为 build_plan 直接读 stdin 解析,Task 3/4 ✓
- §5 选择语义(优先区全测、非亚太 N=5、--iperf-all 扩全区、码大小写不敏感)→ Task 3 测试逐条断言 ✓
- §6 校验(per-region 正整数、未知码硬失败)→ Task 2 ✓
- §7 顶部常量 → Task 1 ✓;§8 报告 ### 子标题 → Task 4 ✓;§9 边界(空组/空计划/下载失败)→ Task 3/4 ✓
- §10 测试(纯逻辑+参数校验+回归)→ Task 3/2/4/5 ✓;§11 文档 → Task 6 ✓;§12 范围外:无 CI/无随机抽样,计划未引入 ✓

**Placeholder 扫描**:无 TBD/TODO;每个代码步给出完整函数体与命令。数据文件节点扩充是**带网络的真实 curation**(给了来源 URL、筛选/排序标准、重点城市清单、lint+集成测试做验收门),非占位。

**类型/命名一致性**:`IPERF_PRIORITY_GROUP/IPERF_DEFAULT_PER_REGION/IPERF_ALL/IPERF_REGION/IPERF_PER_REGION/IPERF_SERVERS_FILE`、`iperf_region_to_group`、`iperf_build_plan`(stdin→`组名<TAB>节点行`)在 Task 1/2/3/4/5 全程一致;计划分隔符统一为 TAB;校验复用现有 `is_uint`。

**说明**:本计划将 spec §4 的「全局 `locs` 扁平数组」细化为「`iperf_build_plan` 直接读 stdin 解析分组」—— 更易单测、消除全局状态,设计意图(选择与执行分离)不变。
