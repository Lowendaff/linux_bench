#!/usr/bin/env bash
# 验证 parse_args:默认全开、--skip-xxx 关单项、netinfo 级联、退出码。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/assert.sh"
LB="$HERE/../linux_bench.sh"

# 在子 shell 里 source 脚本 + 跑 parse_args,打印某个变量的值(子 shell 的 EXIT trap 会自清理临时目录)
val() {
    local v="$1"; shift
    ( source "$LB" 2>/dev/null; parse_args "$@" >/dev/null 2>&1; echo "${!v}" )
}

# 默认:全部开启
assert_eq "$(val RUN_GB)"     "true" "默认 RUN_GB=true"
assert_eq "$(val RUN_IPERF)"  "true" "默认 RUN_IPERF=true"
assert_eq "$(val RUN_SYSINFO)" "true" "默认 RUN_SYSINFO=true"

# 单项 skip
assert_eq "$(val RUN_GB --skip-gb)"   "false" "--skip-gb 关闭 RUN_GB"
assert_eq "$(val RUN_CPU --skip-gb)"  "true"  "--skip-gb 不影响 CPU"
assert_eq "$(val RUN_CPU --skip-cpu)" "false" "--skip-cpu 关闭 CPU"
assert_eq "$(val RUN_GB --skip-cpu)"  "true"  "--skip-cpu 不影响 GB(已解耦)"
assert_eq "$(val RUN_CF --skip-cloudflare)" "false" "--skip-cloudflare 关闭 CF"
assert_eq "$(val RUN_APPLE --skip-cloudflare)" "true" "--skip-cloudflare 不影响 Apple"

# 组 skip
assert_eq "$(val RUN_IPERF --skip-speedtest)" "false" "--skip-speedtest 关 iperf"
assert_eq "$(val RUN_APPLE --skip-speedtest)" "false" "--skip-speedtest 关 apple"
assert_eq "$(val RUN_CPU --skip-speedtest)"   "true"  "--skip-speedtest 不碰 CPU"
assert_eq "$(val RUN_DISK --skip-hardware)"   "false" "--skip-hardware 关磁盘"
assert_eq "$(val RUN_IPERF --skip-hardware)"  "true"  "--skip-hardware 不碰 iperf"

# netinfo 级联
assert_eq "$(val RUN_BGP --skip-netinfo)"    "false" "--skip-netinfo 级联关 BGP"
assert_eq "$(val RUN_TRACE --skip-netinfo)"  "false" "--skip-netinfo 级联关回程"
assert_eq "$(val RUN_IPERF --skip-netinfo)"  "false" "--skip-netinfo 级联关 iperf"
assert_eq "$(val RUN_CPU --skip-netinfo)"    "true"  "--skip-netinfo 不碰 CPU"
assert_eq "$(val RUN_CF --skip-netinfo)"     "true"  "--skip-netinfo 不碰 Cloudflare"

# 顺序无关
assert_eq "$(val RUN_CPU --skip-apple --skip-cpu)"   "false" "顺序无关: CPU 仍被关"
assert_eq "$(val RUN_APPLE --skip-apple --skip-cpu)" "false" "顺序无关: Apple 仍被关"

# 修饰开关
assert_eq "$(val SKIP_V6 -4)" "true" "-4 设 SKIP_V6"
assert_eq "$(val SKIP_V4 -6)" "true" "-6 设 SKIP_V4"

# 退出码
assert_fail    bash -c "source '$LB' 2>/dev/null; parse_args --bogus"  # 未知选项 -> 退出 1
assert_fail    bash -c "source '$LB' 2>/dev/null; parse_args -n"       # 已移除的旧 flag -> 退出 1
assert_success bash -c "source '$LB' 2>/dev/null; parse_args --help"   # 帮助 -> 退出 0

finish
