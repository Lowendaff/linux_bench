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
assert_eq "$(tot "$out")" "8" "AS,EU: 共8(亚太3+欧洲5)"

out=$( source "$LB" 2>/dev/null; IPERF_REGION="AS,EU,AF"; IPERF_PER_REGION="2"; iperf_build_plan < "$FIX" )
assert_eq "$(cnt "$out" 亚太)" "3" "per-region=2: 亚太仍全3(不受影响)"
assert_eq "$(cnt "$out" 欧洲)" "2" "per-region=2: 欧洲2"
assert_eq "$(cnt "$out" 非洲)" "2" "per-region=2: 非洲2"
assert_eq "$(tot "$out")" "7" "AS,EU,AF per=2: 共7(亚太3+欧洲2+非洲2)"

out=$( source "$LB" 2>/dev/null; IPERF_ALL="true"; iperf_build_plan < "$FIX" )
assert_eq "$(tot "$out")" "19" "iperf-all: 全5区全测=19"

out=$( source "$LB" 2>/dev/null; IPERF_REGION="eu"; iperf_build_plan < "$FIX" )
assert_eq "$(cnt "$out" 欧洲)" "5" "小写 eu 等同 EU"

out=$( source "$LB" 2>/dev/null; IPERF_REGION="OC"; iperf_build_plan < "$FIX" )
assert_eq "$(tot "$out")" "0" "OC 合法但样本无该组 -> 0"

out=$( source "$LB" 2>/dev/null; IPERF_ALL="true"; IPERF_REGION="EU,NA"; iperf_build_plan < "$FIX" )
assert_eq "$(cnt "$out" 欧洲)" "6" "all+region: 欧洲全测(6,不受 top-N)"
assert_eq "$(cnt "$out" 北美)" "2" "all+region: 北美全测(2)"
assert_eq "$(cnt "$out" 亚太)" "0" "all+region: 仅选中区(无亚太)"
assert_eq "$(tot "$out")"      "8" "all+region: EU,NA 全测=8"

out=$( source "$LB" 2>/dev/null; IPERF_REGION="EU"; IPERF_DEFAULT_PER_REGION="3"; iperf_build_plan < "$FIX" )
assert_eq "$(cnt "$out" 欧洲)" "3" "IPERF_DEFAULT_PER_REGION=3 生效 -> 欧洲3"

finish
