#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/assert.sh"
source "$HERE/../linux_bench.sh" 2>/dev/null

trap - EXIT
[ -n "${TMP_DIR:-}" ] && rm -rf "$TMP_DIR" 2>/dev/null

output="$(print_feature_list)"

for option in \
    --skip-sysinfo --skip-netinfo --skip-bgp --skip-ip-quality --skip-service \
    --skip-cpu --skip-gb --skip-disk --skip-iperf --skip-cloudflare --skip-apple \
    --skip-trace --skip-forward --skip-hardware --skip-speedtest \
    -4 -6 --raw --normalize --fix-dns --iperf-all --iperf-region --iperf-per-region \
    --help; do
    assert_contains "$output" "$option" "功能列表包含开关: $option"
done

assert_contains "$output" "级联跳过 BGP、IP 质量、服务解锁、iperf3 和路由追踪" "说明 netinfo 级联行为"
assert_contains "$output" "TCP 回程路由追踪" "说明回程追踪使用 TCP"
assert_contains "$output" "DNS 端口 53，CDN/其他端口 80" "说明回程追踪端口策略"
assert_contains "$output" "ICMP 去程路由追踪" "说明去程追踪使用 ICMP"
assert_contains "$output" "AS/EU/NA/SA/OC/AF" "说明 iperf3 地区代码"

for removed in \
    "感谢 JamChoi" \
    "Google Antigravity" \
    "本项目依赖" \
    "IP 信息来源" \
    "干干净净"; do
    if grep -q "$removed" "$HERE/../linux_bench.sh"; then
        found=yes
    else
        found=no
    fi
    assert_eq "$found" "no" "启动页已删除: $removed"
done

finish
