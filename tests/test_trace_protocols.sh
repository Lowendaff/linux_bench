#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/assert.sh"
source "$HERE/../linux_bench.sh" 2>/dev/null

trap - EXIT
[ -n "${TMP_DIR:-}" ] && rm -rf "$TMP_DIR" 2>/dev/null

trace_body="$(sed -n '/^run_trace_test() {/,/^}/p' "$HERE/../linux_bench.sh")"
forward_body="$(sed -n '/^run_forward_trace_test() {/,/^}/p' "$HERE/../linux_bench.sh")"

assert_contains "$trace_body" '--json --tcp --port "$target_port" --psize 1400' "回程追踪使用目标端口与 1400 字节探测包"
assert_contains "$trace_body" 'Cloudflare DNS|1.1.1.1||53' "Cloudflare DNS 使用 TCP/53"
assert_contains "$trace_body" 'Google DNS|8.8.8.8||53' "Google DNS 使用 TCP/53"
assert_contains "$trace_body" 'Quad9 DNS|9.9.9.9||53' "Quad9 DNS 使用 TCP/53"
assert_contains "$trace_body" 'YouTube CDN (Dynamic)|$v4||80' "YouTube CDN 使用 TCP/80"
assert_contains "$trace_body" 'Netflix CDN (Dynamic)|$nf||80' "Netflix CDN 使用 TCP/80"
assert_eq "$(normalize_trace_port "")" "80" "未指定端口时默认 TCP/80"
assert_eq "$(normalize_trace_port "53")" "53" "保留有效的 DNS 端口"
assert_eq "$(normalize_trace_port "invalid")" "80" "无效端口回退为 TCP/80"
assert_contains "$forward_body" "--json --from" "去程追踪使用默认 ICMP"

if [[ "$forward_body" == *'--tcp'* || "$forward_body" == *'--udp'* || "$forward_body" == *'--psize'* ]]; then
    unexpected_probe_option=yes
else
    unexpected_probe_option=no
fi
assert_eq "$unexpected_probe_option" "no" "去程追踪不应指定 TCP、UDP 或 psize"

finish
