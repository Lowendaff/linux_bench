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
