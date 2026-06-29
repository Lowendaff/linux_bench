#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/assert.sh"
source "$HERE/../linux_bench.sh" 2>/dev/null

# 0) setup_nexttrace_token 函数必须已定义
assert_success bash -c "source '$HERE/../linux_bench.sh' 2>/dev/null && declare -F setup_nexttrace_token >/dev/null"

# 1) 用户提供的 token 必须被保留
export NEXTTRACE_TOKEN="user-provided-token"
setup_nexttrace_token
assert_eq "${NEXTTRACE_TOKEN:-}" "user-provided-token" "应保留用户提供的 NEXTTRACE_TOKEN"

# 2) 未提供时不应被硬编码值填充
unset NEXTTRACE_TOKEN
setup_nexttrace_token
assert_eq "${NEXTTRACE_TOKEN:-EMPTY}" "EMPTY" "未提供时不应注入硬编码 token"

# 3) 源码中不得再含 base64 token 大 blob 的前缀(当前文件中该 blob 以 ZXlKaGJHY2lP 开头)
assert_fail grep -q "ZXlKaGJHY2lP" "$HERE/../linux_bench.sh"

finish
