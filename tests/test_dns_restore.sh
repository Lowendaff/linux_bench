#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/assert.sh"
source "$HERE/../linux_bench.sh" 2>/dev/null
# 清理 source 脚本时创建的临时目录(本测试随后覆盖 TMP_DIR/EXIT trap,否则会泄漏空目录)
[ -n "${TMP_DIR:-}" ] && rm -rf "$TMP_DIR" 2>/dev/null

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export TMP_DIR="$WORK/tmp"; mkdir -p "$TMP_DIR"

# 场景 A:普通文件
resolv="$WORK/resolv_regular"
printf 'nameserver 192.0.2.1\n' > "$resolv"
DNS_OVERRIDE_APPLIED=false
apply_dns_override "$resolv"
assert_contains "$(cat "$resolv")" "1.1.1.1" "覆盖后应包含公共 DNS"
restore_dns_override "$resolv"
assert_eq "$(cat "$resolv")" "nameserver 192.0.2.1" "普通文件应被完整还原"

# 场景 B:符号链接(模拟 systemd-resolved stub)
target="$WORK/stub-resolv.conf"
printf 'nameserver 127.0.0.53\n' > "$target"
linkpath="$WORK/resolv_symlink"
ln -s "$target" "$linkpath"
rm -f "$TMP_DIR/resolv.conf.bak"
DNS_OVERRIDE_APPLIED=false
apply_dns_override "$linkpath"
assert_contains "$(cat "$linkpath")" "1.1.1.1" "覆盖后(经链接或替换)应含公共 DNS"
restore_dns_override "$linkpath"
assert_eq "$([ -L "$linkpath" ] && echo symlink || echo file)" "symlink" "原为符号链接应还原为符号链接"
assert_eq "$(readlink "$linkpath")" "$target" "符号链接目标应还原"

# 场景 C:幂等 —— 未覆盖时 restore 不报错
DNS_OVERRIDE_APPLIED=false
assert_success restore_dns_override "$resolv"

finish
