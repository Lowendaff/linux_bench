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
assert_contains "$trace_body" 'Cloudflare DNS||2606:4700:4700::1111|53' "Cloudflare DNS 保留 IPv6"
assert_contains "$trace_body" 'YouTube CDN (Dynamic)||$v6|80' "YouTube CDN 保留 IPv6"
assert_contains "$trace_body" 'Netflix CDN (Dynamic)||$nf|80' "Netflix CDN 保留 IPv6"
assert_contains "$trace_body" 'normalize_static_trace_target "$line"' "静态目标使用独立解析语义"
assert_contains "$trace_body" '[ "$current_group" = "中国境内目标" ] && static_protocol="tcp"' "中国节点选择 TCP"
assert_contains "$trace_body" 'raw_output=$("$NEXTTRACE_BIN" --json $ipflag "$target"' "海外节点使用默认 ICMP"

assert_eq "$(normalize_static_trace_target '北京测试|203.0.113.10|443' tcp)" "北京测试|203.0.113.10||443|tcp" "中国静态目标支持 IPv4、端口和 TCP"
assert_eq "$(normalize_static_trace_target '海外测试|endpoint.example.com' icmp)" "海外测试|endpoint.example.com||80|icmp" "海外静态目标使用 ICMP"
assert_eq "$(normalize_static_trace_target '旧格式|198.51.100.2|2001:db8::2|8443' tcp)" "旧格式|198.51.100.2||8443|tcp" "旧格式忽略 IPv6 并保留端口"
assert_fail normalize_static_trace_target '|203.0.113.10|80'
assert_fail normalize_static_trace_target '无效协议|203.0.113.10|80' udp

invalid_static_rows=$(awk -F'|' '!/^#/ && NF && (NF < 2 || NF > 3 || $1 == "" || $2 == "") {count++} END {print count+0}' "$HERE/../utils/trace_targets.txt")
assert_eq "$invalid_static_rows" "0" "静态目标均符合名称、目标、端口三列语义"
mainland_rows=$(sed -n '/^#GROUP:中国境内目标$/,/^#GROUP:/p' "$HERE/../utils/trace_targets.txt" | sed '1d;$d' | sed '/^$/d')
assert_eq "$(printf '%s\n' "$mainland_rows" | wc -l | tr -d ' ')" "18" "中国大陆静态目标共 18 个"
assert_contains "$mainland_rows" '北京电信 CN2 AS4809|218.30.179.14|161' "北京 CN2 节点已更新"
assert_contains "$mainland_rows" '上海联通 A网(CNC) AS9929|210.13.66.246|47001' "上海 9929 节点已更新"
assert_contains "$mainland_rows" '广州移动 CMIN2 AS58807|120.236.114.59|28382' "广州 CMIN2 节点已更新"
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
