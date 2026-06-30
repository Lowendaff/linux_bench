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
