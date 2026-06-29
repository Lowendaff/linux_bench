#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/assert.sh"
source "$HERE/../linux_bench.sh" 2>/dev/null
# 清理 source 脚本时创建的临时目录(本测试随后覆盖 TMP_DIR,否则会泄漏空目录)
[ -n "${TMP_DIR:-}" ] && rm -rf "$TMP_DIR" 2>/dev/null

# 用独立临时目录,避免影响真实环境
export TMP_DIR="$(mktemp -d)"
FIX_DNS=false
CLEANUP_PKGS=()
SPINNER_PID=""
unset _CLEANED 2>/dev/null || true

# 第一次 cleanup:应删除 TMP_DIR
cleanup
# 第二次:重建 TMP_DIR 与标记,若幂等守卫生效则不应再删除标记
mkdir -p "$TMP_DIR"; touch "$TMP_DIR/marker"
cleanup
assert_eq "$([ -f "$TMP_DIR/marker" ] && echo kept || echo removed)" "kept" "二次 cleanup 应被幂等守卫拦截"

rm -rf "$TMP_DIR"
finish
