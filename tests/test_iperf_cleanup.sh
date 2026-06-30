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
