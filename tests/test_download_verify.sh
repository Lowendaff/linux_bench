#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/assert.sh"
source "$HERE/../linux_bench.sh" 2>/dev/null

FIX="$HERE/fixtures/sample.bin"
TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_OUT"' EXIT

# 用与实现一致的方式计算期望哈希(兼容 mac/Linux)
good="$(_sha256 "$FIX")"
bad="0000000000000000000000000000000000000000000000000000000000000000"

# 1) 正确哈希 -> 成功,且产物存在
assert_success download_and_verify "file://$FIX" "$TMP_OUT" "$good" "fixture"
assert_eq "$(_sha256 "$TMP_OUT")" "$good" "下载产物内容应与夹具一致"

# 2) 错误哈希 -> 失败(非零退出),且产物被删除
assert_fail download_and_verify "file://$FIX" "$TMP_OUT" "$bad" "fixture"
assert_eq "$([ -f "$TMP_OUT" ] && echo exists || echo gone)" "gone" "哈希不匹配时应删除产物"

# 3) 空期望哈希 -> 必须失败(强制提供哈希)
assert_fail download_and_verify "file://$FIX" "$TMP_OUT" "" "fixture"

finish
