#!/usr/bin/env bash
# 验证脚本可被 source 而不执行 main / 不触发前置退出,且关键函数已定义。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/assert.sh"

# source 不应退出当前 shell,也不应打印 ASCII 欢迎语(main 未执行)
out="$(source "$HERE/../linux_bench.sh" 2>&1; echo "SOURCED_OK")"
assert_contains "$out" "SOURCED_OK" "source 脚本后控制权应返回(main 未自动执行)"

# 关键函数在 source 后应已定义
( source "$HERE/../linux_bench.sh" 2>/dev/null
  declare -F preflight_checks >/dev/null ) && echo "ok: preflight_checks 已定义" || { echo "FAIL: preflight_checks 未定义"; }

( source "$HERE/../linux_bench.sh" 2>/dev/null
  declare -F retry_download >/dev/null ) && echo "ok: retry_download 已定义" || { echo "FAIL: retry_download 未定义"; }

finish
