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
