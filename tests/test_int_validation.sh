#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/assert.sh"
source "$HERE/../linux_bench.sh" 2>/dev/null

assert_success is_uint 42
assert_fail    is_uint ""
assert_fail    is_uint 12.5
assert_fail    is_uint abc
assert_success is_num 12.5
assert_success is_num 7
assert_fail    is_num ""

# format_fraud_score: 整数与小数都不应报错,分桶正确(输出形如 "值|评级")
assert_eq "$(format_fraud_score 10  | cut -d'|' -f2)" "🟢 低"  "10 -> 低"
assert_eq "$(format_fraud_score 12.5| cut -d'|' -f2)" "🟢 低"  "小数 12.5 -> 低(不报错)"
assert_eq "$(format_fraud_score 80  | cut -d'|' -f2)" "🔴 高"  "80 -> 高"
assert_eq "$(format_fraud_score ''  )" "N/A|—"               "空 -> N/A"

finish
