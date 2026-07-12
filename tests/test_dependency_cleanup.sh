#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/assert.sh"
source "$HERE/../linux_bench.sh" 2>/dev/null

# 禁止 source 进来的 EXIT trap 操作测试环境，并清理其创建的临时目录。
trap - EXIT
[ -n "${TMP_DIR:-}" ] && rm -rf "$TMP_DIR" 2>/dev/null

# 只测试基础依赖管理，不下载临时工具或运行任何 benchmark。
RUN_CPU=false
RUN_GB=false
RUN_DISK=false
RUN_IPERF=false
RUN_TRACE=false
RUN_FORWARD_TRACE=false
RUN_CF=false
RUN_APPLE=false
check_cmd() { return 0; }

APT_CALLS=""
MOCK_JQ_INSTALLED=true

is_package_installed() {
    if [ "$1" = "jq" ]; then
        [ "$MOCK_JQ_INSTALLED" = "true" ]
    else
        return 0
    fi
}

apt-get() {
    APT_CALLS+="$*"$'\n'
    if [ "${1:-}" = "install" ]; then
        MOCK_JQ_INSTALLED=true
    fi
    return 0
}

# 已预装的包（尤其 xz-utils）不得触发安装，也不得加入清理列表。
TMP_DIR="$(mktemp -d)"
CLEANUP_PKGS=()
ensure_dependencies >/dev/null
assert_eq "${#CLEANUP_PKGS[@]}" "0" "预装依赖不应加入清理列表"
assert_eq "$APT_CALLS" "" "全部依赖已安装时不应调用 apt-get"
rm -rf "$TMP_DIR"

# 缺失包成功安装后，只记录该包；cleanup 只精确 remove，不运行 autoremove。
TMP_DIR="$(mktemp -d)"
CLEANUP_PKGS=()
APT_CALLS=""
MOCK_JQ_INSTALLED=false
unset _CLEANED 2>/dev/null || true
ensure_dependencies >/dev/null
assert_eq "${CLEANUP_PKGS[*]}" "jq" "只记录本次新安装的包"
assert_contains "$APT_CALLS" "install -y -q jq" "缺失包应通过 apt-get 安装"

APT_CALLS=""
cleanup >/dev/null
assert_contains "$APT_CALLS" "remove -y jq" "cleanup 应只移除本次安装的包"
if [[ "$APT_CALLS" == *"autoremove"* ]]; then
    autoremove_seen=yes
else
    autoremove_seen=no
fi
assert_eq "$autoremove_seen" "no" "cleanup 不应运行无边界 autoremove"

finish
