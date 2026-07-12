#!/usr/bin/env bash
# -*- coding: utf-8 -*-

# Copyright (C) 2026  Linux Bench
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# 仅启用 pipefail:让管道中任一环失败都能被感知。
# 注意:有意不启用 set -e / set -u —— 脚本大量使用 `cmd || true` 与可空变量,
# 贸然开启会改变现有控制流。后续如需引入需配合完整回归(见 P2 路线图)。
set -o pipefail

# =========================
# 系统前置检查 (仅在脚本被直接执行时由 main 调用)
# =========================
preflight_checks() {
    if [ "$(uname)" != "Linux" ]; then
        echo "错误: 本脚本仅允许在 Linux 系统上执行。"
        exit 1
    fi
    if [ ! -f /etc/os-release ]; then
        echo "错误: 无法识别系统类型。"
        exit 1
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "$ID" != "debian" && "$ID" != "ubuntu" ]]; then
        echo "错误: 本脚本仅支持 Debian 和 Ubuntu 系统。"
        echo "当前系统: $PRETTY_NAME"
        exit 1
    fi
    if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
        echo "错误: 本脚本需要 root 权限或 sudo 权限。"
        exit 1
    fi
}

# =========================
# 配置 & 全局变量
# =========================
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/linux_bench.XXXXXX")"

# 清理列表 (记录新安装的依赖，以便脚本结束时清理)
CLEANUP_PKGS=()

# 运行开关:默认全部开启,用 --skip-xxx 关闭单项功能(解析见 parse_args / --help)
RUN_SYSINFO=true        # 系统信息
RUN_NET_INFO=true       # 网络信息(IP/ASN/地理) —— 多数网络功能的前置
RUN_BGP=true            # BGP 透视
RUN_IP_QUALITY=true     # IP 质量检测
RUN_STREAM=true         # 服务解锁(流媒体/AIGC)
RUN_CPU=true            # CPU (sysbench)
RUN_GB=true             # Geekbench 6
RUN_DISK=true           # 磁盘 (fio)
RUN_IPERF=true          # iperf3 带宽
RUN_CF=true             # Cloudflare 测速
RUN_APPLE=true          # Apple CDN 测速
RUN_TRACE=true          # 回程路由追踪
RUN_FORWARD_TRACE=true  # 去程路由追踪

# iperf3 地区选择(详见 --help / parse_args / iperf_build_plan)
IPERF_PRIORITY_GROUP="亚太"   # 优先区:默认全测,且不受 --iperf-per-region 约束
IPERF_DEFAULT_PER_REGION=5    # 非优先区默认每区上限
IPERF_ALL=false               # --iperf-all:运行集内所有区全测
IPERF_REGION=""               # --iperf-region=<AS,EU,NA,SA,OC,AF>(空=默认仅亚太)
IPERF_PER_REGION=""           # --iperf-per-region=<N>(空=用默认上限)
IPERF_SERVERS_FILE=""         # get_iperf3_servers 下载后填充的本地路径

# 修饰开关
SKIP_V4=false
SKIP_V6=false
NORMALIZE_OUTPUT=false  # 数据标准化(地名去后缀、运营商名统一)
RAW_OUTPUT=true         # 默认输出原始未标准化数据
FIX_DNS=false           # 强制覆盖 DNS

# DNS 覆盖状态(用于精确恢复)
DNS_OVERRIDE_APPLIED=false
DNS_ORIG_WAS_SYMLINK=false
DNS_ORIG_SYMLINK_TARGET=""

# 报告文件名
REPORT_FILE="bench_report_$(date +%Y%m%d_%H%M%S).md"

# 用法说明
print_usage() {
    cat <<'USAGE'
用法: linux_bench.sh [选项]

默认运行全部测试。用 --skip-xxx 关闭单项功能(可叠加,顺序无关)。

功能开关(默认全开):
  --skip-sysinfo       跳过 系统信息
  --skip-netinfo       跳过 网络信息(会级联关闭依赖它的网络项)
  --skip-bgp           跳过 BGP 透视
  --skip-ip-quality    跳过 IP 质量检测
  --skip-service       跳过 服务解锁(流媒体/AIGC)
  --skip-cpu           跳过 CPU 测试(sysbench)
  --skip-gb            跳过 Geekbench 6
  --skip-disk          跳过 磁盘测试(fio)
  --skip-iperf         跳过 iperf3 带宽测试
  --skip-cloudflare    跳过 Cloudflare 测速
  --skip-apple         跳过 Apple CDN 测速
  --skip-trace         跳过 回程路由追踪
  --skip-forward       跳过 去程路由追踪
  --skip-hardware      跳过 全部硬件测试(= cpu + gb + disk)
  --skip-speedtest     跳过 全部测速(= iperf + cloudflare + apple)

修饰选项:
  -4                   仅 IPv4
  -6                   仅 IPv6
  --raw                原始输出(默认)
  --normalize          标准化输出(地名去后缀、运营商名统一)
  --fix-dns            测试期间临时覆盖系统 DNS
  --iperf-all          iperf3: 全部 6 个地区全测(默认仅全测亚太)
  --iperf-region=<码>  iperf3: 只测指定地区,逗号分隔。码: AS 亚太/EU 欧洲/NA 北美/SA 南美/OC 大洋洲/AF 非洲
  --iperf-per-region=N iperf3: 非亚太地区每区最多测 N 个(默认 5;亚太恒为全测)
  -h, --help           显示本帮助并退出

示例:
  linux_bench.sh                                       # 全部
  linux_bench.sh --skip-gb                             # 全部但跳过最慢的 Geekbench
  linux_bench.sh --skip-speedtest --skip-trace --skip-forward
  linux_bench.sh -4 --skip-gb                          # 仅 IPv4 + 跳过 GB
USAGE
}

print_feature_list() {
    cat <<'FEATURES'
功能开关（默认全部启用，可叠加使用）:
  --skip-sysinfo        跳过系统信息（CPU、内存、磁盘、系统与虚拟化信息）
  --skip-netinfo        跳过网络信息，并级联跳过 BGP、IP 质量、服务解锁、iperf3 和路由追踪
  --skip-bgp            跳过 IPv4/IPv6 BGP 透视
  --skip-ip-quality     跳过 IPv4 欺诈、滥用、机房、原生、VPN、代理及 Tor 检测
  --skip-service        跳过流媒体、游戏平台及 AIGC 服务解锁检测
  --skip-cpu            跳过 sysbench CPU 单线程与多线程测试
  --skip-gb             跳过 Geekbench 6 综合基准测试
  --skip-disk           跳过 fio 4K 随机及 128K 顺序读写测试
  --skip-iperf          跳过 iperf3 多地区双向带宽测试
  --skip-cloudflare     跳过 Cloudflare CDN 速度与延迟测试
  --skip-apple          跳过 Apple CDN 速度与延迟测试
  --skip-trace          跳过 IPv4/IPv6 TCP 回程路由追踪
  --skip-forward        跳过全球节点 TCP 去程路由追踪

组合开关:
  --skip-hardware       跳过全部硬件测试（CPU + Geekbench 6 + 磁盘）
  --skip-speedtest      跳过全部测速（iperf3 + Cloudflare + Apple CDN）

运行选项:
  -4                    仅运行 IPv4 相关测试
  -6                    仅运行 IPv6 相关测试
  --raw                 保留原始地名和运营商名称（默认）
  --normalize           标准化地名后缀和运营商名称
  --fix-dns             测试期间临时使用公共 DNS，结束时恢复原配置
  --iperf-all           iperf3 全部 6 个地区全测
  --iperf-region=<码>   iperf3 只测指定地区，支持 AS/EU/NA/SA/OC/AF，多个用逗号分隔
  --iperf-per-region=N  限制非亚太地区每区最多 N 个节点（默认 5，亚太不受限制）
  -h, --help            显示完整帮助并退出
FEATURES
}

# 参数解析:默认全开,--skip-xxx 关单项;顺序无关(在 main 中调用)
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --skip-sysinfo)    RUN_SYSINFO=false ;;
            --skip-netinfo)    RUN_NET_INFO=false ;;
            --skip-bgp)        RUN_BGP=false ;;
            --skip-ip-quality) RUN_IP_QUALITY=false ;;
            --skip-service)    RUN_STREAM=false ;;
            --skip-cpu)        RUN_CPU=false ;;
            --skip-gb)         RUN_GB=false ;;
            --skip-disk)       RUN_DISK=false ;;
            --skip-iperf)      RUN_IPERF=false ;;
            --skip-cloudflare) RUN_CF=false ;;
            --skip-apple)      RUN_APPLE=false ;;
            --skip-trace)      RUN_TRACE=false ;;
            --skip-forward)    RUN_FORWARD_TRACE=false ;;
            --skip-hardware)   RUN_CPU=false; RUN_GB=false; RUN_DISK=false ;;
            --skip-speedtest)  RUN_IPERF=false; RUN_CF=false; RUN_APPLE=false ;;
            -4)                SKIP_V6=true ;;
            -6)                SKIP_V4=true ;;
            --raw)             RAW_OUTPUT=true; NORMALIZE_OUTPUT=false ;;
            --normalize)       NORMALIZE_OUTPUT=true; RAW_OUTPUT=false ;;
            --fix-dns)         FIX_DNS=true ;;
            --iperf-all)       IPERF_ALL=true ;;
            --iperf-region=*)
                IPERF_REGION="${1#*=}"
                local _codes _c
                IFS=',' read -ra _codes <<< "$IPERF_REGION"
                for _c in "${_codes[@]}"; do
                    [ -z "$_c" ] && continue
                    iperf_region_to_group "$_c" >/dev/null 2>&1 || {
                        fail "未知 --iperf-region 地区: '$_c'。可选: AS,EU,NA,SA,OC,AF。"; exit 1; }
                done
                ;;
            --iperf-per-region=*)
                IPERF_PER_REGION="${1#*=}"
                { is_uint "$IPERF_PER_REGION" && [ "$IPERF_PER_REGION" -ge 1 ]; } || {
                    fail "--iperf-per-region 需为正整数,得到 '$IPERF_PER_REGION'。"; exit 1; }
                ;;
            -h|--help)         print_usage; exit 0 ;;
            # 已移除的旧「套餐」flag —— 给出迁移提示
            -n|--network|--hardware|-t|--nexttrace|-i|--ip-quality|-s|--service|-f|--forward|-p|--public|--speedtest)
                fail "选项 '$1' 已移除:现在默认运行全部测试,请改用 --skip-xxx 关闭单项。见 --help。"
                exit 1
                ;;
            *)
                fail "未知选项: '$1'。见 --help。"
                exit 1
                ;;
        esac
        shift
    done

    # 级联:网络信息是 BGP/IP质量/服务解锁/iperf/回程/去程的前置(它们需要 HAS_V4/V6 或本机 IP)
    if [ "$RUN_NET_INFO" = "false" ]; then
        RUN_BGP=false
        RUN_IP_QUALITY=false
        RUN_STREAM=false
        RUN_IPERF=false
        RUN_TRACE=false
        RUN_FORWARD_TRACE=false
    fi
}

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
SKYBLUE='\033[0;36m'
NC='\033[0m'

# 后台进度条 PID
SPINNER_PID=""

# 应用临时 DNS 覆盖,记录原状态以便精确恢复。
apply_dns_override() {
    local resolv="${1:-/etc/resolv.conf}"
    DNS_OVERRIDE_APPLIED=false
    DNS_ORIG_WAS_SYMLINK=false
    DNS_ORIG_SYMLINK_TARGET=""

    if [ -L "$resolv" ]; then
        DNS_ORIG_WAS_SYMLINK=true
        DNS_ORIG_SYMLINK_TARGET="$(readlink "$resolv")"
    fi
    if [ -e "$resolv" ]; then
        cp -L "$resolv" "$TMP_DIR/resolv.conf.bak" 2>/dev/null || {
            warn "  └─ 无法备份 resolv.conf,跳过 --fix-dns"; return 1; }
    fi
    # 若是符号链接,先删除以免写穿到 stub 目标;删除失败则中止(避免写穿)
    if [ -L "$resolv" ]; then
        rm -f "$resolv" 2>/dev/null || { warn "  └─ 无法移除符号链接 $resolv,跳过 --fix-dns"; return 1; }
    fi
    if printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 2606:4700:4700::1111\n' > "$resolv" 2>/dev/null; then
        DNS_OVERRIDE_APPLIED=true
        return 0
    fi
    warn "  └─ 无法写入 resolv.conf(只读/immutable?),跳过 --fix-dns"
    return 1
}

# 恢复 DNS。幂等:未覆盖时直接返回。
restore_dns_override() {
    local resolv="${1:-/etc/resolv.conf}"
    [ "$DNS_OVERRIDE_APPLIED" = "true" ] || return 0

    if [ "$DNS_ORIG_WAS_SYMLINK" = "true" ] && [ -n "$DNS_ORIG_SYMLINK_TARGET" ]; then
        rm -f "$resolv" 2>/dev/null
        if ln -s "$DNS_ORIG_SYMLINK_TARGET" "$resolv" 2>/dev/null; then
            DNS_OVERRIDE_APPLIED=false; return 0
        fi
    elif [ -f "$TMP_DIR/resolv.conf.bak" ]; then
        if cp "$TMP_DIR/resolv.conf.bak" "$resolv" 2>/dev/null; then
            DNS_OVERRIDE_APPLIED=false; return 0
        fi
    fi
    warn "  ⚠️ 未能自动恢复 $resolv,请手动检查 DNS 配置!"
    return 1
}

# 信号捕捉 - 清理临时文件和依赖
cleanup() {
    [ -n "${_CLEANED:-}" ] && return 0
    _CLEANED=1
    # 0. 先清理临时 swap（必须在删除 TMP_DIR 之前执行）
    local swap_file="$TMP_DIR/gb6_swapfile"
    if [ -f "$swap_file" ]; then
        swapoff "$swap_file" 2>/dev/null || true
    fi

    # 0.5 恢复 DNS
    if [ "$DNS_OVERRIDE_APPLIED" = "true" ]; then
        echo "  ├─ 恢复系统 DNS 配置..."
        restore_dns_override
    fi

    # 1. 删除临时文件
    rm -rf "$TMP_DIR" 2>/dev/null || true

    # 2. 移除脚本安装的依赖 (只清理新安装的)
    if [ "${#CLEANUP_PKGS[@]}" -gt 0 ] 2>/dev/null; then
        echo ""
        log "清理本次安装的依赖..."
        echo "  ├─ 卸载: ${CLEANUP_PKGS[*]}"
        apt-get remove -y "${CLEANUP_PKGS[@]}" >/dev/null 2>&1 || true
        echo -e "  └─ 清理完成 ${GREEN}✓${NC}"
    fi

    # 3. 清理后台进度条
    if [ -n "$SPINNER_PID" ]; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null
        SPINNER_PID=""
    fi
}

# 中断处理 - 询问是否保留结果
interrupt_handler() {
    echo ""
    echo -e "${YELLOW}[中断] 检测到 Ctrl+C，测试未完成${NC}"

    # 检查报告文件是否存在
    if [ -f "$REPORT_FILE" ]; then
        echo -e "${YELLOW}是否保留已生成的测试结果？${NC}"
        echo -n "输入 y 保留，直接回车删除 (默认: 删除): "
        read -r keep_result </dev/tty 2>/dev/null || keep_result=""

        if [ "$keep_result" = "y" ] || [ "$keep_result" = "Y" ] || [ "$keep_result" = "yes" ]; then
            echo -e "${GREEN}[保留] 测试结果已保存到: $REPORT_FILE${NC}"
        else
            rm -f "$REPORT_FILE" 2>/dev/null || true
            echo -e "${YELLOW}[删除] 测试结果已删除${NC}"
        fi
    fi

    cleanup
    echo -e "\n[退出] 脚本已终止"
    exit 1
}

trap interrupt_handler INT TERM
trap cleanup EXIT

# =========================
# 工具函数
# =========================
get_time() {
    date "+%H:%M:%S"
}

log() {
    echo -e "[$(get_time)] $1"
}

info() {
    echo -e "[$(get_time)] ${GREEN}$1${NC}"
}

warn() {
    echo -e "[$(get_time)] ${YELLOW}$1${NC}"
}

fail() {
    echo -e "[$(get_time)] ${RED}$1${NC}"
}

calc() {
    awk "BEGIN {printf \"%.2f\", $1}"
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
is_num()  { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
# GB6 免费版分数只在上传后的结果页可见;VPS 上该页常被 Cloudflare 拦截 → 本机抓不到分数。
# 参数:单核分数、多核分数、结果 URL。两分数都空但有 URL(=上传成功、抓取被挡)时为真。
gb6_scores_blocked() { [ -z "$1" ] && [ -z "$2" ] && [ -n "$3" ]; }

# 地区码 -> 中文组名(大小写不敏感);未知码 return 1。用 tr 折叠大小写以兼容 bash 3.2。
iperf_region_to_group() {
    local code
    code=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
    case "$code" in
        AS) echo "亚太" ;;
        EU) echo "欧洲" ;;
        NA) echo "北美" ;;
        SA) echo "南美" ;;
        OC) echo "大洋洲" ;;
        AF) echo "非洲" ;;
        *)  return 1 ;;
    esac
}

# 纯选择函数:stdin=服务器列表文本;按 IPERF_* 开关输出选中的 "组名<TAB>节点行"。
# 规则:运行集 = IPERF_REGION 指定的区(替换默认)| IPERF_ALL 时全部出现的区 | 否则仅优先区。
# 上限   = 优先区或 IPERF_ALL -> 不限;否则 IPERF_PER_REGION(空则 IPERF_DEFAULT_PER_REGION)。
iperf_build_plan() {
    local priority="${IPERF_PRIORITY_GROUP:-亚太}"
    local default_n="${IPERF_DEFAULT_PER_REGION:-5}"
    local all="${IPERF_ALL:-false}"
    local region="${IPERF_REGION:-}"
    local per="${IPERF_PER_REGION:-}"

    # 由地区码解析显式运行集(中文组名,换行分隔,前后带换行便于整组匹配)
    local have_region=false run_set=$'\n'
    if [ -n "$region" ]; then
        have_region=true
        local _codes _c _g
        IFS=',' read -ra _codes <<< "$region"
        for _c in "${_codes[@]}"; do
            [ -z "$_c" ] && continue
            _g=$(iperf_region_to_group "$_c") || continue
            run_set="${run_set}${_g}"$'\n'
        done
    fi

    local cur="" count=0 line cap
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        if [[ "$line" == "#GROUP:"* ]]; then
            cur="${line#*#GROUP:}"
            count=0
            continue
        fi
        [[ "$line" == "#"* ]] && continue
        [ -z "$cur" ] && continue

        # 当前组是否在运行集内?
        if $have_region; then
            [[ "$run_set" == *$'\n'"$cur"$'\n'* ]] || continue
        elif [ "$all" = "true" ]; then
            :
        else
            [ "$cur" = "$priority" ] || continue
        fi

        # 该组上限(-1 = 不限)
        if [ "$cur" = "$priority" ] || [ "$all" = "true" ]; then
            cap=-1
        elif [ -n "$per" ]; then
            cap="$per"
        else
            cap="$default_n"
        fi
        if [ "$cap" -ge 0 ] && [ "$count" -ge "$cap" ]; then
            continue
        fi

        printf '%s\t%s\n' "$cur" "$line"
        count=$((count+1))
    done
}

# 格式化欺诈评分 (0-100, 越低越好); 支持整数和小数
format_fraud_score() {
    local score="$1"
    if [ -z "$score" ] || [ "$score" = "null" ]; then
        echo "N/A|—"
        return
    fi
    if ! is_num "$score"; then echo "N/A|—"; return; fi
    local bucket
    bucket="$(awk -v s="$score" 'BEGIN{ if (s<40) print "low"; else if (s<70) print "mid"; else print "high" }')"
    case "$bucket" in
        low)  echo "$score|🟢 低" ;;
        mid)  echo "$score|🟡 中" ;;
        *)    echo "$score|🔴 高" ;;
    esac
}

check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# Debian/Ubuntu 包安装状态必须由 dpkg 判断，不能把包名当作命令名检查。
# 例如 xz-utils 提供的是 xz 命令；command -v xz-utils 会把已安装包误判为缺失。
is_package_installed() {
    [ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" = "install ok installed" ]
}

# NextTrace Token:不再硬编码。若用户通过环境变量提供则使用之，
# 否则 nexttrace 以无 token 模式运行（地理数据可能受限）。
setup_nexttrace_token() {
    if [ -n "${NEXTTRACE_TOKEN:-}" ]; then
        export NEXTTRACE_TOKEN
    fi
}

# 计算文件 sha256(优先 sha256sum,回退 shasum -a 256)
_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    else
        shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    fi
}

# 通用重试下载函数
# 参数: $1=输出文件, $2=URL, $3=描述名称(可选), $4=额外curl参数(可选,字符串兼容旧调用)
# 重试策略: 3次重试，间隔分别为5秒、10秒、30秒
retry_download() {
    local output_file="$1"
    local url="$2"
    local name="${3:-文件}"
    # extra_args 兼容旧的"字符串"调用,内部转数组,避免未引用词分割隐患。
    # 将固定参数与可选参数合并为一个数组,避免在 bash 3.2 + set -u 下空数组展开报错。
    local -a curl_args=(-f -L -s)
    if [ -n "${4:-}" ]; then
        local -a _extra=()
        read -r -a _extra <<< "${4}"
        curl_args+=("${_extra[@]}")
    fi

    local retry_delays=(5 10 30)
    local max_retries=3
    local attempt=0

    while [ $attempt -le $max_retries ]; do
        if [ $attempt -eq 0 ]; then
            # 第一次尝试
            if curl "${curl_args[@]}" -o "$output_file" "$url" 2>/dev/null; then
                return 0
            fi
        else
            # 重试
            local delay=${retry_delays[$((attempt-1))]}
            echo -e " ${YELLOW}重试 ($attempt/$max_retries, ${delay}秒后)${NC}"
            sleep $delay
            echo -n "  │  ├─ 重试下载 $name..."
            if curl "${curl_args[@]}" -o "$output_file" "$url" 2>/dev/null; then
                return 0
            fi
        fi
        attempt=$((attempt + 1))
    done

    return 1
}

# 注:已实现但尚未接入下载调用点(校验和接线为延后任务 T5);当前下载仍走 retry_download。
# 带 sha256 校验的下载。expected 为空则直接失败(强制调用方提供哈希)。
# 用法: download_and_verify <url> <out> <sha256> [name] [curl额外参数字符串]
download_and_verify() {
    local url="$1" out="$2" expected="$3" name="${4:-文件}" extra="${5:-}"

    if [ -z "$expected" ]; then
        fail "  └─ 缺少 $name 的期望 sha256,拒绝执行未校验的下载"
        return 1
    fi

    if ! retry_download "$out" "$url" "$name" "$extra"; then
        return 1
    fi

    local actual
    actual="$(_sha256 "$out")"
    if [ "$actual" != "$expected" ]; then
        fail "  └─ $name 校验失败:期望 $expected,实际 ${actual:-<空>}"
        rm -f "$out" 2>/dev/null || true
        return 1
    fi
    return 0
}

# =========================
# 依赖管理
# =========================
ensure_dependencies() {
    log "正在检查依赖..."

    local target_pkgs="curl jq tar xz-utils"

    # 根据开关添加依赖(各功能独立)
    [ "$RUN_CPU" = "true" ] && target_pkgs="$target_pkgs sysbench"
    [ "$RUN_DISK" = "true" ] && target_pkgs="$target_pkgs fio"
    [ "$RUN_IPERF" = "true" ] && target_pkgs="$target_pkgs iperf3"

    local missing_pkgs=""
    local installed_pkgs=""

    # 1. 检查缺失的包。使用 dpkg 状态，确保只记录安装前确实不存在的包。
    # shellcheck disable=SC2086 # 故意词分割: 包列表
    for pkg in $target_pkgs; do
        if is_package_installed "$pkg"; then
            installed_pkgs="$installed_pkgs $pkg"
        else
            missing_pkgs="$missing_pkgs $pkg"
        fi
    done

    # 显示已安装的依赖
    if [ -n "$installed_pkgs" ]; then
        echo "  ├─ 已安装:$installed_pkgs"
    fi

    # 2. 安装缺失的包
    if [ -n "$missing_pkgs" ]; then
        echo "  ├─ 需安装:$missing_pkgs"

        export DEBIAN_FRONTEND=noninteractive

        # 更新软件源
        echo -n "  │  ├─ 更新软件源..."
        if ! apt-get update -y -q >/dev/null 2>&1; then
            echo -e " ${RED}失败${NC}"
            fail "软件源更新失败，请检查网络连接。"
            exit 1
        fi
        echo -e " ${GREEN}完成${NC}"

        # 安装依赖包
        echo -n "  │  └─ 安装依赖包..."
        # shellcheck disable=SC2086 # 故意词分割: 包列表
        if apt-get install -y -q $missing_pkgs >/dev/null 2>&1; then
            echo -e " ${GREEN}完成${NC}"
            # 只记录安装前不存在、且现在已成功安装的包，以便精确清理。
            # shellcheck disable=SC2086 # 故意词分割: 包列表
            for p in $missing_pkgs; do
                if is_package_installed "$p"; then
                    CLEANUP_PKGS+=("$p")
                fi
            done
        else
            echo -e " ${RED}失败${NC}"
            fail "依赖安装失败，请检查网络或软件源配置。"
            fail "尝试手动安装: sudo apt-get install $missing_pkgs"
            exit 1
        fi
    fi

    # 3. 二次验证
    local verify_fail=false
    for cmd in curl jq; do
        if ! check_cmd "$cmd"; then
            fail "关键依赖 $cmd 仍未找到，脚本无法继续。"
            verify_fail=true
        fi
    done
    [ "$verify_fail" = "true" ] && exit 1

    # 4. Ephemeral Binaries (NextTrace, yt-dlp, Geekbench6, cf-speed)
    # Ensure TMP_DIR exists for all modes (used by fio, logs, etc)
    mkdir -p "$TMP_DIR"

    # 预判需要下载的临时工具
    local ephemeral_tools=""

    if [ "$RUN_TRACE" = "true" ] || [ "$RUN_FORWARD_TRACE" = "true" ]; then
        ephemeral_tools="$ephemeral_tools nexttrace"
    fi
    [ "$RUN_TRACE" = "true" ] && ephemeral_tools="$ephemeral_tools yt-dlp"
    [ "$RUN_CF" = "true" ] && ephemeral_tools="$ephemeral_tools cf-speed"
    [ "$RUN_APPLE" = "true" ] && ephemeral_tools="$ephemeral_tools inetspeed"
    [ "$RUN_GB" = "true" ] && ephemeral_tools="$ephemeral_tools geekbench6"

    # 输出临时工具列表
    [ -n "$ephemeral_tools" ] && info "下载临时工具:$ephemeral_tools"

    # 实际下载 - NextTrace (回程/去程追踪需要)
    if [ "$RUN_TRACE" = "true" ] || [ "$RUN_FORWARD_TRACE" = "true" ]; then
        local arch=$(uname -m)
        local url=""
        [ "$arch" == "x86_64" ] && url="https://github.com/nxtrace/NTrace-core/releases/latest/download/nexttrace_linux_amd64"
        [ "$arch" == "aarch64" ] && url="https://github.com/nxtrace/NTrace-core/releases/latest/download/nexttrace_linux_arm64"

        echo -n "  ├─ 正在下载 nexttrace..."
        if [ -n "$url" ] && retry_download "$TMP_DIR/nexttrace" "$url" "nexttrace"; then
            chmod +x "$TMP_DIR/nexttrace"
            export NEXTTRACE_BIN="$TMP_DIR/nexttrace"
            echo -e " ${GREEN}完成${NC}"
        else
            export NEXTTRACE_BIN="false"
            echo -e " ${RED}失败${NC}"
        fi
        # 设置 NextTrace Token（不再硬编码；尊重用户环境变量）
        setup_nexttrace_token
    else
        export NEXTTRACE_BIN="false"
    fi

    # 实际下载 - yt-dlp (仅回程追踪需要，用于获取 YouTube CDN)
    if [ "$RUN_TRACE" = "true" ]; then
        echo -n "  ├─ 正在下载 yt-dlp..."
        if retry_download "$TMP_DIR/yt-dlp" "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp" "yt-dlp"; then
            chmod +x "$TMP_DIR/yt-dlp"
            export YTDLP_BIN="$TMP_DIR/yt-dlp"
            echo -e " ${GREEN}完成${NC}"
        else
            export YTDLP_BIN="false"
            echo -e " ${RED}失败${NC}"
        fi
    else
        export YTDLP_BIN="false"
    fi

    # 实际下载 - Cloudflare Speedtest CLI
    if [ "$RUN_CF" = "true" ]; then
        local arch=$(uname -m)
        local cf_url=""

        case "$arch" in
            x86_64)
                cf_url="https://github.com/kavehtehrani/cloudflare-speed-cli/releases/latest/download/cloudflare-speed-cli-x86_64-unknown-linux-musl.tar.xz"
                ;;
            aarch64)
                cf_url="https://github.com/kavehtehrani/cloudflare-speed-cli/releases/latest/download/cloudflare-speed-cli-aarch64-unknown-linux-musl.tar.xz"
                ;;
            *)
                warn "  └─ 不支持的架构: $arch，跳过 cf-speed"
                export CFSPEED_BIN="false"
                ;;
        esac

        if [ -n "$cf_url" ]; then
            local cf_tarball="$TMP_DIR/cloudflare-speed-cli.tar.xz"
            echo -n "  ├─ 正在下载 cf-speed..."

            local download_success=false
            if retry_download "$cf_tarball" "$cf_url" "cf-speed"; then
                download_success=true
            fi

            if [ "$download_success" = "true" ]; then
                if tar -xJf "$cf_tarball" -C "$TMP_DIR" 2>/dev/null; then
                    local cf_bin=$(find "$TMP_DIR" -name "cloudflare-speed-cli" -type f 2>/dev/null | head -n1)
                    if [ -n "$cf_bin" ] && [ -f "$cf_bin" ]; then
                        chmod +x "$cf_bin"
                        export CFSPEED_BIN="$cf_bin"
                        echo -e " ${GREEN}完成${NC}"
                    else
                        export CFSPEED_BIN="false"
                        echo -e " ${RED}失败${NC}"
                    fi
                else
                    export CFSPEED_BIN="false"
                    echo -e " ${RED}失败${NC}"
                fi
                rm -f "$cf_tarball"
            else
                export CFSPEED_BIN="false"
                echo -e " ${RED}失败${NC}"
            fi
        fi
    else
        export CFSPEED_BIN="false"
    fi

    # 实际下载 - iNetSpeed-CLI (Apple CDN Speedtest)
    if [ "$RUN_APPLE" = "true" ]; then
        local arch=$(uname -m)
        local inetspeed_url=""
        case "$arch" in
            x86_64)
                inetspeed_url="https://github.com/tsosunchia/iNetSpeed-CLI/releases/download/v1.0.9/speedtest-linux-amd64"
                ;;
            aarch64)
                inetspeed_url="https://github.com/tsosunchia/iNetSpeed-CLI/releases/download/v1.0.9/speedtest-linux-arm64"
                ;;
            *)
                warn "  └─ 不支持的架构: $arch，跳过 iNetSpeed"
                export INETSPEED_BIN="false"
                ;;
        esac

        if [ -n "$inetspeed_url" ]; then
            echo -n "  ├─ 正在下载 inetspeed (Apple CDN)..."
            if retry_download "$TMP_DIR/inetspeed" "$inetspeed_url" "inetspeed"; then
                chmod +x "$TMP_DIR/inetspeed"
                export INETSPEED_BIN="$TMP_DIR/inetspeed"
                echo -e " ${GREEN}完成${NC}"
            else
                export INETSPEED_BIN="false"
                echo -e " ${RED}失败${NC}"
            fi
        fi
    else
        export INETSPEED_BIN="false"
    fi

    # 实际下载 - Geekbench 6 (有进度提示)
    if [ "$RUN_GB" = "true" ]; then
        local arch=$(uname -m)
        # 6.7.1:旧版 6.5.0 自带的 TLS 栈过旧,结果上传到 Geekbench Browser 会 TLS 握手失败
        # (libcurl code 35)→ 免费版拿不到分 → 误报"测试失败"。6.7.x 自带新 TLS 栈,上传正常(实测验证)。
        local gb6_version="6.7.1"
        local gb6_url=""

        case "$arch" in
            x86_64)
                gb6_url="https://cdn.geekbench.com/Geekbench-${gb6_version}-Linux.tar.gz"
                ;;
            aarch64)
                gb6_url="https://cdn.geekbench.com/Geekbench-${gb6_version}-LinuxARMPreview.tar.gz"
                ;;
            *)
                warn "  └─ 不支持的架构: $arch，跳过 Geekbench 6"
                export GB6_BIN="false"
                ;;
        esac

        if [ -n "$gb6_url" ]; then
            local gb6_tarball="$TMP_DIR/geekbench6.tar.gz"
            echo -n "  ├─ 正在下载 Geekbench 6..."

            local download_success=false
            if retry_download "$gb6_tarball" "$gb6_url" "Geekbench 6"; then
                download_success=true
            fi

            if [ "$download_success" = "true" ]; then
                if tar -xzf "$gb6_tarball" -C "$TMP_DIR" 2>/dev/null; then
                    local gb6_bin=$(find "$TMP_DIR" -name "geekbench6" -type f 2>/dev/null | head -n1)
                    if [ -n "$gb6_bin" ] && [ -f "$gb6_bin" ]; then
                        chmod +x "$gb6_bin"
                        export GB6_BIN="$gb6_bin"
                        echo -e " ${GREEN}完成${NC}"
                    else
                        echo -e " ${RED}失败${NC}"
                        warn "  │  └─ 未找到 geekbench6 可执行文件"
                        export GB6_BIN="false"
                    fi
                else
                    echo -e " ${RED}失败${NC}"
                    warn "  │  └─ 解压失败"
                    export GB6_BIN="false"
                fi
                rm -f "$gb6_tarball"
            else
                echo -e " ${RED}失败${NC}"
                warn "  │  └─ 下载失败"
                export GB6_BIN="false"
            fi
        fi
    else
        export GB6_BIN="false"
    fi

    info "所有依赖已就绪 ✓"
}

# =========================
# 系统信息
# =========================
collect_system_info() {
    log "开始系统信息收集..."

    # 1. CPU
    echo "  ├─ 检测 CPU 信息..."
    if check_cmd lscpu; then
        SYS_CPU=$(lscpu | grep "Model name:" | cut -d: -f2 | xargs)
        SYS_CORES=$(lscpu | grep "CPU(s):" | head -n1 | cut -d: -f2 | xargs)
        # Cache
        local l1=$(lscpu | grep "L1" | grep "cache" | head -n1 | awk '{print $3$4}')
        local l2=$(lscpu | grep "L2" | grep "cache" | head -n1 | awk '{print $3$4}')
        local l3=$(lscpu | grep "L3" | grep "cache" | head -n1 | awk '{print $3$4}')
        [ -z "$l1" ] && l1="-"
        [ -z "$l2" ] && l2="-"
        [ -z "$l3" ] && l3="-"
        SYS_CACHE="L1: $l1 / L2: $l2 / L3: $l3"
    else
        SYS_CPU=$(cat /proc/cpuinfo | grep "model name" | head -n1 | cut -d: -f2 | xargs)
        SYS_CORES=$(grep -c ^processor /proc/cpuinfo)
        SYS_CACHE="Unknown"
    fi
    [ -z "$SYS_CPU" ] && SYS_CPU="Unknown"
    echo "  │  └─ CPU: $SYS_CPU ($SYS_CORES vCPU)"

    # 2. Virtualization
    echo "  ├─ 检测虚拟化类型..."
    SYS_VIRT=$(systemd-detect-virt 2>/dev/null)
    if [ -z "$SYS_VIRT" ]; then
        SYS_VIRT=$(hostnamectl 2>/dev/null | grep "Virtualization" | cut -d: -f2 | xargs)
    fi
    [ -z "$SYS_VIRT" ] && SYS_VIRT="Physical/Unknown"
    echo "  │  └─ 虚拟化: $SYS_VIRT"

    # 3. RAM / SWAP
    echo "  ├─ 检测内存信息..."
    if check_cmd free; then
        local mem_total=$(free -m | awk '/Mem:/ {print $2}')
        local mem_used=$(free -m | awk '/Mem:/ {print $3}')
        local swap_total=$(free -m | awk '/Swap:/ {print $2}')
        local swap_used=$(free -m | awk '/Swap:/ {print $3}')
        is_uint "$swap_total" || swap_total=0
        SYS_MEM="${mem_used}MiB / ${mem_total}MiB"
        if [ "$swap_total" -eq 0 ]; then
            SYS_SWAP="0 (Disabled)"
        else
            SYS_SWAP="${swap_used}MiB / ${swap_total}MiB"
        fi
    else
        SYS_MEM="Unknown"
        SYS_SWAP="Unknown"
    fi
    echo "  │  └─ 内存: $SYS_MEM"

    # 4. Disk
    echo "  ├─ 检测磁盘信息..."
    local root_disk=$(df -h / | tail -n1)
    local disk_total=$(echo "$root_disk" | awk '{print $2}')
    local disk_used=$(echo "$root_disk" | awk '{print $3}')
    local disk_dev=$(echo "$root_disk" | awk '{print $1}')
    SYS_DISK="${disk_used} / ${disk_total} ($disk_dev)"
    echo "  │  └─ 磁盘: $SYS_DISK"

    # 5. OS / Kernel（使用脚本开头已加载的 /etc/os-release 变量）
    SYS_OS="${PRETTY_NAME:-$(uname -srm)}"
    SYS_KERNEL=$(uname -r)
    echo "  └─ 系统: $SYS_OS ($SYS_KERNEL)"

    # === Streaming Report ===
    {
        echo "## 系统信息"
        echo "| 测试项目 | 测试结果 |"
        echo "| :--- | :--- |"
        echo "| CPU 型号 | $SYS_CPU |"
        echo "| CPU 核心 | $SYS_CORES |"
        echo "| CPU 缓存 | $SYS_CACHE |"
        echo "| 虚拟化类型 | $SYS_VIRT |"
        echo "| 内存使用 | $SYS_MEM |"
        echo "| Swap 使用 | $SYS_SWAP |"
        echo "| 磁盘使用 | $SYS_DISK |"
        echo "| 系统发行版 | $SYS_OS |"
        echo "| 内核版本 | $SYS_KERNEL |"
        echo ""
    } >> "$REPORT_FILE"
}

# =========================
# 网络信息
# =========================
collect_network_info() {
    log "开始网络信息收集..."

    # 使用 ipapi.co，它同时支持 IPv4 和 IPv6 访问
    # 字段映射：ip=IP地址, org=组织, asn=AS号, city=城市, country_code=国家代码

    if [ "$SKIP_V4" = "false" ]; then
        echo "  ├─ 查询 IPv4 信息..."
        local v4_json=""
        local v4_source=""
        local v4_success=false

        # 定义多个 API 源
        local v4_apis=(
            "https://ipapi.co/json/"
            "https://api.ip.sb/geoip"
            "https://ipinfo.io/json"
        )
        local v4_api_names=("ipapi.co" "ip.sb" "ipinfo.io")

        for i in "${!v4_apis[@]}"; do
            local api_url="${v4_apis[$i]}"
            local api_name="${v4_api_names[$i]}"

            local retry_delays=(5 10 30)
            local max_retries=3
            local attempt=0
            local current_api_success=false

            while [ $attempt -le $max_retries ]; do
                if [ $attempt -eq 0 ]; then
                    v4_json=$(curl -s -4 --connect-timeout 5 --max-time 10 "$api_url" 2>/dev/null)
                    if [ -n "$v4_json" ] && echo "$v4_json" | jq -e '.ip' >/dev/null 2>&1; then
                        current_api_success=true
                        break
                    fi
                else
                    local delay=${retry_delays[$((attempt-1))]}
                    echo -e "  │  ├─ IPv4 查询 ($api_name) 失败，${YELLOW}重试 ($attempt/$max_retries, ${delay}秒后)${NC}"
                    sleep $delay
                    v4_json=$(curl -s -4 --connect-timeout 5 --max-time 10 "$api_url" 2>/dev/null)
                    if [ -n "$v4_json" ] && echo "$v4_json" | jq -e '.ip' >/dev/null 2>&1; then
                        current_api_success=true
                        break
                    fi
                fi
                attempt=$((attempt+1))
            done

            if [ "$current_api_success" = "true" ]; then
                v4_source="$api_name"
                v4_success=true
                break
            fi

            if [ $i -lt $((${#v4_apis[@]} - 1)) ]; then
                echo "  │  ├─ IPv4 检测失效 ($api_name)，尝试备用源..."
            fi
        done

        if [ "$v4_success" = "true" ]; then
            HAS_V4="true"
            NET_V4_IP=$(echo "$v4_json" | jq -r '.ip // empty')

            # 根据不同 API 解析字段（兼容不同返回格式）
            case "$v4_source" in
                "ipapi.co")
                    NET_V4_ORG=$(echo "$v4_json" | jq -r '.org // empty')
                    NET_V4_ASN=$(echo "$v4_json" | jq -r '.asn // empty' | sed 's/AS//')
                    NET_V4_LOC="$(echo "$v4_json" | jq -r '.city // empty'), $(echo "$v4_json" | jq -r '.country_code // empty')"
                    ;;
                "ip.sb")
                    NET_V4_ORG=$(echo "$v4_json" | jq -r '.organization // .isp // empty')
                    NET_V4_ASN=$(echo "$v4_json" | jq -r '.asn // empty' | sed 's/AS//')
                    NET_V4_LOC="$(echo "$v4_json" | jq -r '.city // empty'), $(echo "$v4_json" | jq -r '.country_code // empty')"
                    ;;
                "ipinfo.io")
                    # ipinfo.io 格式: org = "AS12345 Company Name"
                    local org_raw=$(echo "$v4_json" | jq -r '.org // empty')
                    NET_V4_ASN=$(echo "$org_raw" | grep -oP '^AS\K[0-9]+' || echo "")
                    NET_V4_ORG=$(echo "$org_raw" | sed 's/^AS[0-9]* //')
                    NET_V4_LOC="$(echo "$v4_json" | jq -r '.city // empty'), $(echo "$v4_json" | jq -r '.country // empty')"
                    ;;
            esac
        else
            HAS_V4=""
            NET_V4_IP="N/A"
            NET_V4_ORG=""
            NET_V4_ASN=""
            NET_V4_LOC=""
        fi
        if [ "$HAS_V4" = "true" ]; then
            if [ "$SKIP_V6" = "true" ]; then
                echo "  └─ IPv4: $NET_V4_IP"
                echo "     ├─ AS${NET_V4_ASN} - ${NET_V4_ORG}"
                echo "     └─ 位置: $NET_V4_LOC"
            else
                echo "  ├─ IPv4: $NET_V4_IP"
                echo "  │  ├─ AS${NET_V4_ASN} - ${NET_V4_ORG}"
                echo "  │  └─ 位置: $NET_V4_LOC"
            fi
        else
            if [ "$SKIP_V6" = "true" ]; then
                echo "  └─ IPv4: N/A"
            else
                echo "  ├─ IPv4: N/A"
            fi
        fi
    fi

    if [ "$SKIP_V6" = "false" ]; then
        if check_cmd ip && ! ip -6 addr show scope global 2>/dev/null | grep -q "inet6"; then
            echo "  └─ IPv6: N/A (未分配全局 IPv6 地址)"
            HAS_V6=""
            NET_V6_IP="N/A"
            NET_V6_ORG=""
            NET_V6_ASN=""
            NET_V6_LOC=""
        else
            echo "  ├─ 查询 IPv6 信息..."
            local v6_json=""
            local v6_source=""
            local v6_success=false

            # 定义多个 API 源（仅支持 IPv6 的服务）
            local v6_apis=(
                "https://ipapi.co/json/"
                "https://api.ip.sb/geoip"
                "https://ipinfo.io/json"
            )
            local v6_api_names=("ipapi.co" "ip.sb" "ipinfo.io")

            for i in "${!v6_apis[@]}"; do
                local api_url="${v6_apis[$i]}"
                local api_name="${v6_api_names[$i]}"

                local retry_delays=(5 10 30)
                local max_retries=3
                local attempt=0
                local current_api_success=false

                while [ $attempt -le $max_retries ]; do
                    if [ $attempt -eq 0 ]; then
                        v6_json=$(curl -s -6 --connect-timeout 5 --max-time 10 "$api_url" 2>/dev/null)
                        if [ -n "$v6_json" ] && echo "$v6_json" | jq -e '.ip' >/dev/null 2>&1; then
                            current_api_success=true
                            break
                        fi
                    else
                        local delay=${retry_delays[$((attempt-1))]}
                        echo -e "  │  ├─ IPv6 查询 ($api_name) 失败，${YELLOW}重试 ($attempt/$max_retries, ${delay}秒后)${NC}"
                        sleep $delay
                        v6_json=$(curl -s -6 --connect-timeout 5 --max-time 10 "$api_url" 2>/dev/null)
                        if [ -n "$v6_json" ] && echo "$v6_json" | jq -e '.ip' >/dev/null 2>&1; then
                            current_api_success=true
                            break
                        fi
                    fi
                    attempt=$((attempt+1))
                done

                if [ "$current_api_success" = "true" ]; then
                    v6_source="$api_name"
                    v6_success=true
                    break
                fi

                if [ $i -lt $((${#v6_apis[@]} - 1)) ]; then
                    echo "  │  ├─ IPv6 检测失效 ($api_name)，尝试备用源..."
                fi
            done

            if [ "$v6_success" = "true" ]; then
                HAS_V6="true"
                NET_V6_IP=$(echo "$v6_json" | jq -r '.ip // empty')

                # 根据不同 API 解析字段（兼容不同返回格式）
                case "$v6_source" in
                    "ipapi.co")
                        NET_V6_ORG=$(echo "$v6_json" | jq -r '.org // empty')
                        NET_V6_ASN=$(echo "$v6_json" | jq -r '.asn // empty' | sed 's/AS//')
                        NET_V6_LOC="$(echo "$v6_json" | jq -r '.city // empty'), $(echo "$v6_json" | jq -r '.country_code // empty')"
                        ;;
                    "ip.sb")
                        NET_V6_ORG=$(echo "$v6_json" | jq -r '.organization // .isp // empty')
                        NET_V6_ASN=$(echo "$v6_json" | jq -r '.asn // empty' | sed 's/AS//')
                        NET_V6_LOC="$(echo "$v6_json" | jq -r '.city // empty'), $(echo "$v6_json" | jq -r '.country_code // empty')"
                        ;;
                    "ipinfo.io")
                        # ipinfo.io 格式: org = "AS12345 Company Name"
                        local org_raw=$(echo "$v6_json" | jq -r '.org // empty')
                        NET_V6_ASN=$(echo "$org_raw" | grep -oP '^AS\K[0-9]+' || echo "")
                        NET_V6_ORG=$(echo "$org_raw" | sed 's/^AS[0-9]* //')
                        NET_V6_LOC="$(echo "$v6_json" | jq -r '.city // empty'), $(echo "$v6_json" | jq -r '.country // empty')"
                        ;;
                esac
            else
                HAS_V6=""
                NET_V6_IP="N/A"
                NET_V6_ORG=""
                NET_V6_ASN=""
                NET_V6_LOC=""
            fi
            if [ "$HAS_V6" = "true" ]; then
                echo "  └─ IPv6: $NET_V6_IP"
                echo "     ├─ AS${NET_V6_ASN} - ${NET_V6_ORG}"
                echo "     └─ 位置: $NET_V6_LOC"
            else
                echo "  └─ IPv6: N/A"
            fi
        fi
    fi

    # === Streaming Report ===
    {
        echo "## 网络信息"
        echo "| 测试项目 | 测试结果 |"
        echo "| :--- | :--- |"
        if [ "$HAS_V4" = "true" ]; then
            local masked_v4=$(echo "$NET_V4_IP" | awk -F. '{print $1"."$2".xx.xx"}')
            echo "| IPv4 - 地址 | $masked_v4 |"
            echo "| IPv4 - AS 信息 | AS$NET_V4_ASN - $NET_V4_ORG |"
            echo "| IPv4 - 地理位置 | $NET_V4_LOC |"
        fi
        if [ "$HAS_V6" = "true" ]; then
            local masked_v6=$(echo "$NET_V6_IP" | awk -F: '{print $1":"$2":xx"}')
            echo "| IPv6 - 地址 | $masked_v6 |"
            echo "| IPv6 - AS 信息 | AS$NET_V6_ASN - $NET_V6_ORG |"
            echo "| IPv6 - 地理位置 | $NET_V6_LOC |"
        fi
        echo ""
    } >> "$REPORT_FILE"
}

# =========================
# BGP 透视
# =========================
collect_bgp_view() {
    log "开始 BGP 透视..."

    local BGP_API_BASE="https://bgp-view.jam114514.me/bgp_info?ip="
    local has_any_bgp=false

    # === IPv4 BGP 透视 ===
    if [ "$SKIP_V4" = "false" ] && [ "$HAS_V4" = "true" ]; then
        echo "  ├─ 获取 IPv4 BGP 信息..."
        local v4_svg_url="${BGP_API_BASE}${NET_V4_IP}"
        echo "  │  ├─ 正在请求后端建立缓存 (最大等待 10s)..."
        
        # 触发后端缓存
        if curl -s -o /dev/null --max-time 10 "$v4_svg_url" 2>/dev/null; then
            echo "  │  ├─ 缓存建立请求成功"
        else
            echo "  │  ├─ 缓存建立超时或失败 (这不影响后续图片链接的生成)"
        fi
        
        BGP_V4_URL="$v4_svg_url"
        has_any_bgp=true
        if [ "$SKIP_V6" = "true" ] || [ "$HAS_V6" != "true" ]; then
            echo "  └─ IPv4 BGP 链接生成 ✓"
        else
            echo "  │  └─ IPv4 BGP 链接生成 ✓"
        fi
    fi

    # === IPv6 BGP 透视 ===
    if [ "$SKIP_V6" = "false" ] && [ "$HAS_V6" = "true" ]; then
        echo "  └─ 获取 IPv6 BGP 信息..."
        local v6_svg_url="${BGP_API_BASE}${NET_V6_IP}"
        echo "     ├─ 正在请求后端建立缓存 (最大等待 10s)..."
        
        # 触发后端缓存
        if curl -s -o /dev/null --max-time 10 "$v6_svg_url" 2>/dev/null; then
            echo "     ├─ 缓存建立请求成功"
        else
            echo "     ├─ 缓存建立超时或失败 (这不影响后续图片链接的生成)"
        fi
        
        BGP_V6_URL="$v6_svg_url"
        has_any_bgp=true
        echo "     └─ IPv6 BGP 链接生成 ✓"
    fi

    # === 生成报告 ===
    if [ "$has_any_bgp" = "true" ]; then
        {
            echo "## BGP 透视"
            echo ""
            if [ -n "$BGP_V4_URL" ]; then
                echo "### IPv4"
                echo "![IPv4 BGP 透视]($BGP_V4_URL)"
                echo ""
            fi
            if [ -n "$BGP_V6_URL" ]; then
                echo "### IPv6"
                echo "![IPv6 BGP 透视]($BGP_V6_URL)"
                echo ""
            fi
        } >> "$REPORT_FILE"
    fi

    info "  └─ BGP 透视完成"
}

# =========================
# IP 质量检测 (仅 IPv4)
# =========================
collect_ip_quality() {
    log "开始 IP 质量检测..."

    # 格式化布尔值为 YES/NO
    format_bool_yesno() {
        local val="$1"
        case "$val" in
            "true"|"True"|"TRUE"|"yes"|"1") echo "✅ **YES**" ;;
            "false"|"False"|"FALSE"|"no"|"0") echo "❌ **NO**" ;;
            *) echo "—" ;;
        esac
    }

    # 格式化滥用评分 (解析 "0.0078 (Low)" 格式)
    format_abuser_score() {
        local raw="$1"
        if [ -z "$raw" ] || [ "$raw" = "null" ]; then
            echo "N/A|—"
            return
        fi
        # 提取数值和评级
        local num=$(echo "$raw" | awk '{print $1}')
        local level=$(echo "$raw" | grep -oP '\(\K[^)]+')

        # 根据评级设置红绿灯 (中文)
        case "$level" in
            "Very Low") echo "$num|🟢 极低" ;;
            "Low") echo "$num|🟢 低" ;;
            "Elevated") echo "$num|🟡 中" ;;
            "High") echo "$num|🟠 高" ;;
            "Very High"|"Critical") echo "$num|🔴 极高" ;;
            *) echo "$num|$level" ;;
        esac
    }

    # === 仅 IPv4 检测 ===
    if [ "$HAS_V4" != "true" ]; then
        warn "  └─ 未检测到 IPv4 地址，跳过 IP 质量检测"
        return
    fi

    local ip="$NET_V4_IP"
    echo "  ├─ [IPv4] 查询质量信息: $ip"

    # 1. ipapi.is - 滥用评分、机房识别、VPN/代理/Tor/爬虫/滥用检测
    echo "  │  ├─ 查询 ipapi.is..."
    local ipapi_json=""
    local ipapi_retry=0
    local quality_max_retry=3

    while [ $ipapi_retry -lt $quality_max_retry ]; do
        ipapi_json=$(curl -s -4 --max-time 10 "https://api.ipapi.is/?q=$ip" 2>/dev/null)
        if [ -n "$ipapi_json" ] && echo "$ipapi_json" | jq -e '.ip' >/dev/null 2>&1; then
            break
        fi
        ipapi_retry=$((ipapi_retry + 1))
        if [ $ipapi_retry -lt $quality_max_retry ]; then
            echo "  │  │  ├─ ipapi.is 查询失败，重试 ($ipapi_retry/$quality_max_retry)..."
            sleep 3
        fi
    done

    local ipapi_abuser_score="" ipapi_asn_abuser_score=""
    local ipapi_is_datacenter="" ipapi_datacenter_name=""
    local ipapi_is_vpn="" ipapi_is_proxy="" ipapi_is_tor="" ipapi_is_crawler="" ipapi_is_abuser=""
    local ipapi_company_type="" ipapi_is_mobile="" ipapi_is_bogon="" ipapi_is_satellite=""

    if [ -n "$ipapi_json" ] && echo "$ipapi_json" | jq -e '.ip' >/dev/null 2>&1; then
        ipapi_abuser_score=$(echo "$ipapi_json" | jq -r '.company.abuser_score // empty')
        ipapi_asn_abuser_score=$(echo "$ipapi_json" | jq -r '.asn.abuser_score // empty')
        ipapi_is_datacenter=$(echo "$ipapi_json" | jq -r 'if .is_datacenter == null then "" else (.is_datacenter | tostring) end')
        ipapi_datacenter_name=$(echo "$ipapi_json" | jq -r '.datacenter.datacenter // empty')
        ipapi_is_vpn=$(echo "$ipapi_json" | jq -r 'if .is_vpn == null then "" else (.is_vpn | tostring) end')
        ipapi_is_proxy=$(echo "$ipapi_json" | jq -r 'if .is_proxy == null then "" else (.is_proxy | tostring) end')
        ipapi_is_tor=$(echo "$ipapi_json" | jq -r 'if .is_tor == null then "" else (.is_tor | tostring) end')
        ipapi_is_crawler=$(echo "$ipapi_json" | jq -r 'if .is_crawler == null then "" else (.is_crawler | tostring) end')
        ipapi_is_abuser=$(echo "$ipapi_json" | jq -r 'if .is_abuser == null then "" else (.is_abuser | tostring) end')
        ipapi_company_type=$(echo "$ipapi_json" | jq -r '.company.type // empty')
        ipapi_is_mobile=$(echo "$ipapi_json" | jq -r 'if .is_mobile == null then "" else (.is_mobile | tostring) end')
        ipapi_is_bogon=$(echo "$ipapi_json" | jq -r 'if .is_bogon == null then "" else (.is_bogon | tostring) end')
        ipapi_is_satellite=$(echo "$ipapi_json" | jq -r 'if .is_satellite == null then "" else (.is_satellite | tostring) end')
    fi

    # 2. ippure - 欺诈评分、原生 IP 识别
    echo "  │  ├─ 查询 ippure.com..."
    local ippure_json=""
    local ippure_retry=0

    while [ $ippure_retry -lt $quality_max_retry ]; do
        ippure_json=$(curl -s -4 --max-time 10 "https://my.ippure.com/v1/info" 2>/dev/null)
        if [ -n "$ippure_json" ] && echo "$ippure_json" | jq -e '.ip' >/dev/null 2>&1; then
            break
        fi
        ippure_retry=$((ippure_retry + 1))
        if [ $ippure_retry -lt $quality_max_retry ]; then
            echo "  │  │  ├─ ippure.com 查询失败，重试 ($ippure_retry/$quality_max_retry)..."
            sleep 3
        fi
    done

    local ippure_fraud_score="" ippure_is_residential=""

    if [ -n "$ippure_json" ] && echo "$ippure_json" | jq -e '.ip' >/dev/null 2>&1; then
        ippure_fraud_score=$(echo "$ippure_json" | jq -r '.fraudScore // empty')
        ippure_is_residential=$(echo "$ippure_json" | jq -r 'if .isResidential == null then "" else (.isResidential | tostring) end')
    fi

    # === 格式化各项评分 ===
    local fraud_formatted=$(format_fraud_score "$ippure_fraud_score")
    local fraud_val=$(echo "$fraud_formatted" | cut -d'|' -f1)
    local fraud_remark=$(echo "$fraud_formatted" | cut -d'|' -f2)

    local abuser_formatted=$(format_abuser_score "$ipapi_abuser_score")
    local abuser_val=$(echo "$abuser_formatted" | cut -d'|' -f1)
    local abuser_remark=$(echo "$abuser_formatted" | cut -d'|' -f2)

    local asn_formatted=$(format_abuser_score "$ipapi_asn_abuser_score")
    local asn_val=$(echo "$asn_formatted" | cut -d'|' -f1)
    local asn_remark=$(echo "$asn_formatted" | cut -d'|' -f2)

    # === 格式化机房识别结果 ===
    local datacenter_result="" datacenter_remark=""
    if [ "$ipapi_is_datacenter" = "true" ]; then
        datacenter_result="✅ **YES**"
        if [ -n "$ipapi_datacenter_name" ] && [ "$ipapi_datacenter_name" != "null" ]; then
            datacenter_remark="$ipapi_datacenter_name"
        fi
    else
        datacenter_result="❌ **NO**"
        datacenter_remark=""
    fi

    # VPN/代理合并检测
    local vpn_proxy_result="false"
    [[ "$ipapi_is_vpn" = "true" || "$ipapi_is_proxy" = "true" ]] && vpn_proxy_result="true"

    # === 终端输出关键结果 ===
    echo "  │  ├─ 欺诈评分: ${ippure_fraud_score:-N/A} | 滥用评分: ${ipapi_abuser_score:-N/A}"
    echo "  │  ├─ 组织类型: ${ipapi_company_type:-N/A} | 机房: ${ipapi_is_datacenter:-N/A} | 移动: ${ipapi_is_mobile:-N/A}"
    echo "  │  ├─ VPN/代理: ${vpn_proxy_result} | Tor: ${ipapi_is_tor:-N/A} | 原生: ${ippure_is_residential:-N/A}"
    echo "  │  └─ 检测完成"

    # === 生成报告 ===
    {
        echo "## IPv4 质量分析"
        echo ""
        echo "| 检测项目 | 检测结果 | 备注 | 数据来源 |"
        echo "| :--- | :--- | :--- | :--- |"
        # 风险评分
        echo "| 欺诈评分 | $fraud_val | $fraud_remark (越低越好) | ippure.com |"
        echo "| 滥用评分 | $abuser_val | $abuser_remark (越低越好) | ipapi.is |"
        echo "| ASN 信誉 | $asn_val | $asn_remark (越低越好) | ipapi.is |"
        # IP 类型
        # 组织类型中文说明
        local company_type_remark=""
        case "$ipapi_company_type" in
            "hosting") company_type_remark="机房/托管" ;;
            "isp") company_type_remark="运营商/宽带" ;;
            "business") company_type_remark="商业机构" ;;
            "education") company_type_remark="教育机构" ;;
            "government") company_type_remark="政府机构" ;;
            "banking") company_type_remark="金融机构" ;;
            *) company_type_remark="" ;;
        esac
        echo "| 组织类型 | ${ipapi_company_type:-N/A} | $company_type_remark | ipapi.is |"
        echo "| 原生识别 | $(format_bool_yesno "$ippure_is_residential") | | ippure.com |"
        echo "| 机房识别 | $datacenter_result | $datacenter_remark | ipapi.is |"
        echo "| 移动网络 | $(format_bool_yesno "$ipapi_is_mobile") | | ipapi.is |"
        echo "| 卫星网络 | $(format_bool_yesno "$ipapi_is_satellite") | Starlink/Viasat等 | ipapi.is |"
        # 安全标识
        echo "| VPN/代理 | $(format_bool_yesno "$vpn_proxy_result") | | ipapi.is |"
        echo "| Tor 节点 | $(format_bool_yesno "$ipapi_is_tor") | | ipapi.is |"
        echo "| 爬虫检测 | $(format_bool_yesno "$ipapi_is_crawler") | | ipapi.is |"
        echo "| 滥用黑名单 | $(format_bool_yesno "$ipapi_is_abuser") | | ipapi.is |"
        # 其他
        echo "| 保留 IP | $(format_bool_yesno "$ipapi_is_bogon") | | ipapi.is |"

    } >> "$REPORT_FILE"

    info "  └─ IP 质量检测完成"
}

# =========================
# 性能测试 (CPU/Disk/Net)
# =========================
run_cpu_test() {
    log "开始 CPU 性能测试..."
    if ! check_cmd sysbench; then warn "  └─ sysbench 未安装，跳过"; return; fi

    echo "  ├─ 单线程测试 (20秒)..."
    local res_1t=$(sysbench --threads=1 --time=20 --cpu-max-prime=10000 cpu run 2>&1)
    local score_1t=$(echo "$res_1t" | grep "events per second:" | awk '{print $4}')
    echo "  │  └─ 单线程结果: $score_1t events/s"

    local score_nt=""
    local multi="1.00"
    if is_uint "$SYS_CORES" && [ "$SYS_CORES" -gt 1 ]; then
        echo "  └─ $SYS_CORES 线程测试 (20秒)..."
        local res_nt=$(sysbench --threads="$SYS_CORES" --time=20 --cpu-max-prime=10000 cpu run 2>&1)
        score_nt=$(echo "$res_nt" | grep "events per second:" | awk '{print $4}')
        multi=$(calc "$score_nt / $score_1t")
        echo "     └─ $SYS_CORES 线程结果: $score_nt events/s (${multi}x)"
    else
        echo "  └─ (单核心，跳过多线程测试)"
    fi

    BENCH_CPU_1T="$score_1t"
    BENCH_CPU_NT="${score_nt:-N/A}"
    BENCH_CPU_MULTI="$multi"

    # === Streaming Report ===
    {
        echo "## CPU 性能测试"
        echo "| 测试项目 | 测试结果 |"
        echo "| :--- | :--- |"
        echo "| 单线程测试 | $BENCH_CPU_1T |"
        echo "| 多线程测试 | $BENCH_CPU_NT ($BENCH_CPU_MULTI x) |"
        echo ""
    } >> "$REPORT_FILE"

    info "  └─ CPU 测试完成"
}

run_gb6_test() {
    log "开始 Geekbench 6 测试..."

    # 检查 GB6_BIN 是否可用
    if [ "$GB6_BIN" = "false" ] || [ -z "$GB6_BIN" ]; then
        warn "  └─ Geekbench 6 未安装或下载失败，跳过"
        return
    fi

    if [ ! -x "$GB6_BIN" ] && ! command -v "$GB6_BIN" >/dev/null 2>&1; then
        warn "  └─ Geekbench 6 不可执行，跳过"
        return
    fi

    # Geekbench 6 需要至少 2GB 内存，检查并创建临时 swap
    local gb6_tmp_swap=""
    local mem_total_mb=$(free -m | awk '/Mem:/ {print $2}')
    local swap_total_mb=$(free -m | awk '/Swap:/ {print $2}')
    is_uint "$mem_total_mb"  || mem_total_mb=0
    is_uint "$swap_total_mb" || swap_total_mb=0
    local total_mb=$((mem_total_mb + swap_total_mb))
    local min_required_mb=2048

    if [ "$total_mb" -lt "$min_required_mb" ]; then
        local need_mb=2048  # 直接创建 2GB swap
        echo "  ├─ 检测到内存不足 (${total_mb}MB < ${min_required_mb}MB)"
        echo "  │  ├─ 创建 ${need_mb}MB 临时 swap..."

        gb6_tmp_swap="$TMP_DIR/gb6_swapfile"
        if dd if=/dev/zero of="$gb6_tmp_swap" bs=1M count="$need_mb" 2>/dev/null && \
           chmod 600 "$gb6_tmp_swap" && \
           mkswap "$gb6_tmp_swap" >/dev/null 2>&1 && \
           swapon "$gb6_tmp_swap" 2>/dev/null; then
            echo "  │  └─ 临时 swap 已启用 ✓"
        else
            warn "  │  └─ 临时 swap 创建失败，测试可能会因内存不足失败"
            gb6_tmp_swap=""
        fi
    fi

    echo "  ├─ 正在运行 Geekbench 6 测试 (约需 3-5 分钟)..."

    # 启动后台进度指示器
    local spinner_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    SPINNER_PID=""
    (
        local i=0
        local start_time=$(date +%s)
        while true; do
            local elapsed=$(($(date +%s) - start_time))
            local mins=$((elapsed / 60))
            local secs=$((elapsed % 60))
            printf "\r  │  ├─ 测试进行中 ${spinner_chars:i++%10:1} [%02d:%02d]" "$mins" "$secs"
            sleep 0.2
        done
    ) &
    SPINNER_PID=$!

    # 运行 Geekbench 6 测试 (免费版会自动上传结果到 Geekbench Browser)
    local gb6_output=""
    gb6_output=$("$GB6_BIN" 2>&1)
    local gb6_exit_code=$?

    # 停止进度指示器
    kill $SPINNER_PID 2>/dev/null
    wait $SPINNER_PID 2>/dev/null
    SPINNER_PID=""

    if [ $gb6_exit_code -ne 0 ]; then
        echo -e "\r  │  └─ Geekbench 6 测试失败 ${RED}✗${NC}              "
        warn "  └─ 测试失败，请检查系统兼容性"
        return
    fi

    echo -e "\r  │  └─ 测试完成 ${GREEN}✓${NC}                        "

    # 解析结果
    local single_score=""
    local multi_score=""
    local result_url=""
    local gb6_version=""
    local cpu_name=""
    local cpu_freq=""
    local cpu_topology=""
    local l3_cache=""
    local instruction_sets=""

    # 先获取 URL
    result_url=$(echo "$gb6_output" | grep -oE 'https://browser\.geekbench\.com/v6/cpu/[0-9]+' | head -n1)

    # 尝试从命令行输出解析分数
    single_score=$(echo "$gb6_output" | grep -i "Single-Core Score" | awk '{print $NF}')
    multi_score=$(echo "$gb6_output" | grep -i "Multi-Core Score" | awk '{print $NF}')

    # 从网页抓取详细信息
    if [ -n "$result_url" ]; then
        echo "  ├─ 从 Geekbench 网站获取详细信息..."
        local page_content=""
        page_content=$(curl -s --max-time 15 "$result_url" 2>/dev/null)
        if [ -n "$page_content" ]; then
            # 如果命令行没有分数，从网页解析
            if [ -z "$single_score" ]; then
                single_score=$(echo "$page_content" | grep -A1 "score-container-1" | grep -oP "(?<=<div class='score'>)[0-9]+(?=</div>)" | head -n1)
                multi_score=$(echo "$page_content" | grep -oP "(?<=<div class='score'>)[0-9]+(?=</div>)" | tail -n1)
            fi
            # 解析 Geekbench 版本 (格式: Geekbench 6.5.0 for Linux AVX2)
            gb6_version=$(echo "$page_content" | grep -oP "Geekbench [0-9]+\.[0-9]+\.[0-9]+ for Linux[^<]*" | head -n1)
            # 解析 CPU 名称 (从 processor link)
            cpu_name=$(echo "$page_content" | grep -oP '(?<=<a href="/processors/)[^"]+">([^<]+)</a>' | sed 's/.*">//' | sed 's/<\/a>//' | head -n1)
            if [ -z "$cpu_name" ]; then
                # 备用方式：从 system-value 中提取
                cpu_name=$(echo "$page_content" | grep -A1 "system-name'>Name" | grep "system-value" | sed "s/.*'system-value'>//" | sed 's/<.*//')
            fi
            # 解析基础频率
            cpu_freq=$(echo "$page_content" | grep -A1 "Base Frequency" | grep "system-value" | sed "s/.*'system-value'>//" | sed 's/<.*//')
            # 解析核心拓扑 (格式: 1 Processor, 1 Core)
            cpu_topology=$(echo "$page_content" | grep -A1 "Topology" | grep "system-value" | sed "s/.*'system-value'>//" | sed 's/<.*//')
            # 解析 L3 缓存
            l3_cache=$(echo "$page_content" | grep -A1 "L3 Cache" | grep "value" | sed "s/.*'value'>//" | sed 's/<.*//')
            # 解析指令集 (简化显示关键的 SIMD 指令集)
            local raw_isa=$(echo "$page_content" | grep -A1 "Instruction Sets" | grep "value" | sed "s/.*'value'>//" | sed 's/<.*//')
            # 只提取重要的 SIMD 指令集
            instruction_sets=""
            [[ "$raw_isa" == *"avx512"* ]] && instruction_sets="AVX-512"
            [[ "$raw_isa" == *"avx2"* ]] && { [ -n "$instruction_sets" ] && instruction_sets="$instruction_sets, AVX2" || instruction_sets="AVX2"; }
            [[ "$raw_isa" == *"avx "* || "$raw_isa" == *"avx,"* ]] && { [ -n "$instruction_sets" ] && instruction_sets="$instruction_sets, AVX" || instruction_sets="AVX"; }
            [[ "$raw_isa" == *"aesni"* ]] && instruction_sets="$instruction_sets, AES-NI"
        fi
    fi

    # 输出结果
    [ -n "$gb6_version" ] && echo "  ├─ 版本: $gb6_version"
    [ -n "$cpu_name" ] && echo "  ├─ 处理器: $cpu_name"
    [ -n "$cpu_freq" ] && echo "  ├─ 基础频率: $cpu_freq"
    [ -n "$cpu_topology" ] && echo "  ├─ 核心拓扑: $cpu_topology"
    [ -n "$l3_cache" ] && echo "  ├─ L3 缓存: $l3_cache"
    [ -n "$instruction_sets" ] && echo "  ├─ 指令集: $instruction_sets"
    echo "  ├─ 单核分数: ${single_score:-N/A}"
    echo "  ├─ 多核分数: ${multi_score:-N/A}"
    if gb6_scores_blocked "$single_score" "$multi_score" "$result_url"; then
        echo "  ├─ 注:本机未能抓取分数(Geekbench Browser 对 VPS 启用了 Cloudflare 防护),请见结果链接"
    fi
    [ -n "$result_url" ] && echo "  ├─ 结果链接: $result_url"

    # 保存到全局变量
    GB6_SINGLE="${single_score:-N/A}"
    GB6_MULTI="${multi_score:-N/A}"
    GB6_URL="${result_url:-}"

    # === Streaming Report ===
    {
        echo "## Geekbench 6 测试"
        echo ""
        [ -n "$gb6_version" ] && echo "版本: $gb6_version"
        echo ""
        echo "| 测试项目 | 测试结果 |"
        echo "| :--- | :--- |"
        [ -n "$cpu_name" ] && echo "| 处理器 | $cpu_name |"
        [ -n "$cpu_freq" ] && echo "| 基础频率 | $cpu_freq |"
        [ -n "$cpu_topology" ] && echo "| 核心拓扑 | $cpu_topology |"
        [ -n "$l3_cache" ] && echo "| L3 缓存 | $l3_cache |"
        [ -n "$instruction_sets" ] && echo "| 指令集 | $instruction_sets |"
        echo "| 单核分数 | $GB6_SINGLE |"
        echo "| 多核分数 | $GB6_MULTI |"
        echo ""
        if gb6_scores_blocked "$single_score" "$multi_score" "$result_url"; then
            echo "> 注:本机未能抓取分数(Geekbench Browser 对 VPS 启用了 Cloudflare 防护),请点下方在线结果链接查看。"
            echo ""
        fi
        if [ -n "$GB6_URL" ]; then
            echo "在线结果: $GB6_URL"
        fi
        echo ""
    } >> "$REPORT_FILE"

    # 清理临时 swap
    if [ -n "$gb6_tmp_swap" ] && [ -f "$gb6_tmp_swap" ]; then
        echo "  ├─ 清理临时 swap..."
        swapoff "$gb6_tmp_swap" 2>/dev/null || true
        rm -f "$gb6_tmp_swap" 2>/dev/null || true
        echo "  │  └─ 临时 swap 已清理 ✓"
    fi

    info "  └─ Geekbench 6 测试完成"
}

run_disk_test() {
    log "开始磁盘性能测试..."
    if ! check_cmd fio; then warn "  └─ fio 未安装，跳过"; return; fi

    local testfile="$TMP_DIR/fio_test"

    # Detect best available ioengine (libaio preferred, fallback to sync)
    local ioengine="sync"
    if [ -e /sys/module/libaio ] || modinfo libaio >/dev/null 2>&1; then
        ioengine="libaio"
    fi

    # Use --minimal output format for reliable parsing (semicolon-delimited)
    # Format: https://fio.readthedocs.io/en/latest/fio_doc.html#minimal-output
    local job_defaults="--ioengine=$ioengine --size=50m --runtime=10 --iodepth=32 --direct=1 --minimal --filename=$testfile"

    parse_fio_minimal() {
        local output="$1"
        local type="$2"  # r or w
        local kbps=0
        local iops=0

        # fio --minimal 输出可能包含警告信息（如 "note: ..."）
        # 需要过滤掉，只保留以数字开头的数据行
        local data_line=$(echo "$output" | grep '^[0-9]')

        # Minimal output is semicolon-delimited
        # Read: field 7 = KB/s, field 8 = IOPS (1-indexed)
        # Write: field 48 = KB/s, field 49 = IOPS (1-indexed)
        if [ -n "$data_line" ]; then
            if [ "$type" = "r" ]; then
                kbps=$(echo "$data_line" | cut -d';' -f7 2>/dev/null)
                iops=$(echo "$data_line" | cut -d';' -f8 2>/dev/null)
            else
                kbps=$(echo "$data_line" | cut -d';' -f48 2>/dev/null)
                iops=$(echo "$data_line" | cut -d';' -f49 2>/dev/null)
            fi
        fi

        # Default to 0 if empty
        kbps=${kbps:-0}
        iops=${iops:-0}

        # Convert KB/s to MB/s (handle empty/non-numeric values)
        if [[ "$kbps" =~ ^[0-9]+\.?[0-9]*$ ]]; then
            local mbps=$(calc "${kbps}/1024")
        else
            local mbps="0.00"
        fi

        if [[ "$iops" =~ ^[0-9]+\.?[0-9]*$ ]]; then
            local iops_int=$(printf "%.0f" "${iops}" 2>/dev/null || echo "0")
        else
            local iops_int="0"
        fi

        echo "$mbps MB/s ($iops_int IOPS)"
    }

    echo "  ├─ [1/4] 写入测试 (4K) (10秒)..."
    local w4=$(fio --name=w4k --rw=randwrite --bs=4k $job_defaults 2>/dev/null)
    local res_w4=$(parse_fio_minimal "$w4" "w")
    echo "  │  └─ 结果: $res_w4"

    echo "  ├─ [2/4] 读取测试 (4K) (10秒)..."
    local r4=$(fio --name=r4k --rw=randread --bs=4k $job_defaults 2>/dev/null)
    local res_r4=$(parse_fio_minimal "$r4" "r")
    echo "  │  └─ 结果: $res_r4"

    echo "  ├─ [3/4] 写入测试 (128K) (10秒)..."
    local w128=$(fio --name=w128k --rw=write --bs=128k $job_defaults 2>/dev/null)
    local res_w128=$(parse_fio_minimal "$w128" "w")
    echo "  │  └─ 结果: $res_w128"

    echo "  ├─ [4/4] 读取测试 (128K) (10秒)..."
    local r128=$(fio --name=r128k --rw=read --bs=128k $job_defaults 2>/dev/null)
    local res_r128=$(parse_fio_minimal "$r128" "r")
    echo "  │  └─ 结果: $res_r128"

    rm -f "$testfile"

    BENCH_DISK_W4="$res_w4"
    BENCH_DISK_R4="$res_r4"
    BENCH_DISK_W128="$res_w128"
    BENCH_DISK_R128="$res_r128"

    # === Streaming Report ===
    {
        echo "## 磁盘性能测试"
        echo "| 测试项目 | 测试结果 |"
        echo "| :--- | :--- |"
        echo "| 写入测试 (4K) | $BENCH_DISK_W4 |"
        echo "| 读取测试 (4K) | $BENCH_DISK_R4 |"
        echo "| 写入测试 (128K) | $BENCH_DISK_W128 |"
        echo "| 读取测试 (128K) | $BENCH_DISK_R128 |"
        echo ""
    } >> "$REPORT_FILE"

    info "  └─ 磁盘测试完成"
}

run_iperf_once() {
    local host="$1"
    local port="$2"
    local parallel="$3"
    local reverse="$4"
    local ipflag="$5"
    local args=("$ipflag" "-c" "$host" "-p" "$port" "-P" "$parallel" "-t" "5")
    [ "$reverse" = "true" ] && args+=("-R")

    local ret="busy"
    for i in 1 2; do
        local out
        # Add timeout to prevent hanging on bad nodes
        out=$(timeout 15 iperf3 "${args[@]}" 2>&1)
        if [[ "$out" == *"receiver"* ]]; then
             local line=$(echo "$out" | grep "receiver" | grep "SUM" | tail -n1)
             [ -z "$line" ] && line=$(echo "$out" | grep "receiver" | tail -n1)
             local val=$(echo "$line" | awk '{print $(NF-2)}')
             local unit=$(echo "$line" | awk '{print $(NF-1)}')
             if [ -n "$val" ] && [ "$val" != "0.00" ]; then
                 ret="$val $unit"
                 break
             fi
        fi
        sleep 1
    done
    echo "$ret"
}

get_iperf3_servers() {
    local servers_url="https://raw.githubusercontent.com/Lowendaff/linux_bench/main/utils/iperf3_servers.txt"
    IPERF_SERVERS_FILE="$TMP_DIR/iperf3_servers.txt"

    if ! retry_download "$IPERF_SERVERS_FILE" "$servers_url" "iPerf3 Servers" "--connect-timeout 5 --max-time 15"; then
        warn "  Failed to download iPerf3 servers."
        IPERF_SERVERS_FILE=""
        return 1
    fi
    return 0
}

run_iperf_test() {
    log "开始网络带宽测试..."
    if ! check_cmd iperf3; then warn "  └─ iperf3 未安装，跳过"; return; fi

    if ! get_iperf3_servers || [ -z "$IPERF_SERVERS_FILE" ]; then
        return
    fi

    # 纯函数选出本次要测的节点(组名<TAB>节点行)
    local plan
    plan=$(iperf_build_plan < "$IPERF_SERVERS_FILE")
    if [ -z "$plan" ]; then
        info "  └─ 无可测 iperf3 节点(检查 --iperf-region / --iperf-all 与节点列表)"
        return
    fi

    echo "## 网络带宽测试" >> "$REPORT_FILE"

    local total cur_group="" idx=0
    total=$(printf '%s\n' "$plan" | awk -F'\t' 'NF>0' | wc -l | tr -d ' ')

    while IFS=$'\t' read -r group entry; do
        [ -z "$entry" ] && continue

        if [ "$group" != "$cur_group" ]; then
            cur_group="$group"
            {
                echo ""
                echo "### $group"
                echo "| IP 类型 | 运营商 | 服务器位置 | 发送带宽 | 接收带宽 | 延迟 |"
                echo "| :--- | :--- | :--- | :--- | :--- | :--- |"
            } >> "$REPORT_FILE"
            echo "  ├─ ${group}节点测试..."
        fi

        idx=$((idx+1))
        IFS='|' read -r host ports provider loc modes <<< "$entry"
        IFS='-' read -r p0 p1 <<< "$ports"
        [ -z "$p1" ] && p1="$p0"
        # 端口字段须为数字(单端口或 N-M 范围);非法则跳过该节点
        # (防御被污染/打错的目录,避免 $((...)) 把端口当算术表达式求值)。
        if ! is_uint "$p0" || ! is_uint "$p1"; then
            warn "  │  ├─ 跳过 $provider $loc:端口字段非法 ('$ports')"
            continue
        fi

        for mode in IPv4 IPv6; do
            if [[ "$modes" != *"$mode"* ]]; then continue; fi
            if [ "$mode" = "IPv4" ] && [ "$HAS_V4" != "true" ]; then continue; fi
            if [ "$mode" = "IPv6" ] && [ "$HAS_V6" != "true" ]; then continue; fi
            local ipflag="-4"; [ "$mode" = "IPv6" ] && ipflag="-6"

            echo "  │  ├─ [$idx/$total] $provider - $loc ($mode)..."
            local p=$((p0 + RANDOM % (p1 - p0 + 1)))
            local send=$(run_iperf_once "$host" "$p" 8 false "$ipflag")
            p=$((p0 + RANDOM % (p1 - p0 + 1)))
            local recv=$(run_iperf_once "$host" "$p" 8 true "$ipflag")
            local lat="--"
            if [ "$mode" = "IPv4" ]; then lat=$(ping -c 1 -W 1 "$host" 2>/dev/null | grep "time=" | awk -F "time=" '{print $2}' | awk '{print $1}'); else lat=$(ping -6 -c 1 -W 1 "$host" 2>/dev/null | grep "time=" | awk -F "time=" '{print $2}' | awk '{print $1}'); fi
            echo "  │  │  └─ 发送: ${send} / 接收: ${recv} / 延迟: ${lat:---} ms"

            echo "| $mode | $provider | $loc | $send | $recv | ${lat:---} ms |" >> "$REPORT_FILE"
        done
    done <<< "$plan"

    echo "" >> "$REPORT_FILE"
    info "  └─ 带宽测试完成"
}

run_cloudflare_speedtest() {
    log "开始 Cloudflare Speedtest..."

    if [ "$CFSPEED_BIN" == "false" ] || [ -z "$CFSPEED_BIN" ]; then
        warn "  └─ cloudflare-speed-cli 未安装或下载失败，跳过"
        return
    fi

    if [ ! -x "$CFSPEED_BIN" ] && ! command -v "$CFSPEED_BIN" >/dev/null 2>&1; then
        warn "  └─ cloudflare-speed-cli ($CFSPEED_BIN) 不可执行，跳过"
        return
    fi

    echo "  ├─ 正在测试 Cloudflare CDN 速度..."

    # 运行测试并获取 JSON 输出
    local json_output
    json_output=$("$CFSPEED_BIN" --json 2>/dev/null)

    if [ -z "$json_output" ] || ! echo "$json_output" | jq -e . >/dev/null 2>&1; then
        warn "  └─ Cloudflare Speedtest 失败: 无效输出"
        return
    fi

    # 解析 JSON 结果
    local cf_ip=$(echo "$json_output" | jq -r '.ip // "N/A"')
    local cf_colo=$(echo "$json_output" | jq -r '.colo // "N/A"')
    local cf_asn=$(echo "$json_output" | jq -r '.asn // "N/A"')
    local cf_city=$(echo "$json_output" | jq -r '.meta.city // "N/A"')
    local cf_country=$(echo "$json_output" | jq -r '.meta.country // "N/A"')

    # 下载速度
    local dl_mbps=$(echo "$json_output" | jq -r '.download.mbps // 0' | xargs printf "%.2f")
    local dl_median=$(echo "$json_output" | jq -r '.download.median_mbps // 0' | xargs printf "%.2f")
    local dl_p25=$(echo "$json_output" | jq -r '.download.p25_mbps // 0' | xargs printf "%.2f")
    local dl_p75=$(echo "$json_output" | jq -r '.download.p75_mbps // 0' | xargs printf "%.2f")

    # 上传速度
    local ul_mbps=$(echo "$json_output" | jq -r '.upload.mbps // 0' | xargs printf "%.2f")
    local ul_median=$(echo "$json_output" | jq -r '.upload.median_mbps // 0' | xargs printf "%.2f")
    local ul_p25=$(echo "$json_output" | jq -r '.upload.p25_mbps // 0' | xargs printf "%.2f")
    local ul_p75=$(echo "$json_output" | jq -r '.upload.p75_mbps // 0' | xargs printf "%.2f")

    # 空闲延迟
    local idle_avg=$(echo "$json_output" | jq -r '.idle_latency.mean_ms // 0' | xargs printf "%.1f")
    local idle_median=$(echo "$json_output" | jq -r '.idle_latency.median_ms // 0' | xargs printf "%.1f")
    local idle_jitter=$(echo "$json_output" | jq -r '.idle_latency.jitter_ms // 0' | xargs printf "%.1f")
    local idle_loss=$(echo "$json_output" | jq -r '.idle_latency.loss // 0' | xargs printf "%.1f")

    # 负载延迟 (下载)
    local loaded_dl_avg=$(echo "$json_output" | jq -r '.loaded_latency_download.mean_ms // 0' | xargs printf "%.1f")
    local loaded_dl_jitter=$(echo "$json_output" | jq -r '.loaded_latency_download.jitter_ms // 0' | xargs printf "%.1f")

    # 负载延迟 (上传)
    local loaded_ul_avg=$(echo "$json_output" | jq -r '.loaded_latency_upload.mean_ms // 0' | xargs printf "%.1f")
    local loaded_ul_jitter=$(echo "$json_output" | jq -r '.loaded_latency_upload.jitter_ms // 0' | xargs printf "%.1f")

    # 控制台输出
    echo "  │  ├─ 节点: $cf_colo ($cf_city, $cf_country)"
    echo "  │  ├─ IP: $cf_ip (AS$cf_asn)"
    echo "  │  ├─ 下载: ${dl_mbps} Mbps (中位数: ${dl_median} Mbps)"
    echo "  │  ├─ 上传: ${ul_mbps} Mbps (中位数: ${ul_median} Mbps)"
    echo "  │  └─ 延迟: ${idle_avg} ms (抖动: ${idle_jitter} ms)"

    # === 写入报告 ===
    {
        echo "## Cloudflare Speedtest"
        echo "测试节点: $cf_colo ($cf_city, $cf_country)"
        echo ""
        echo "### 速度测试"
        echo "| 方向 | 速度 | 中位数 | P25 | P75 |"
        echo "|:---|---:|---:|---:|---:|"
        echo "| 下载 | ${dl_mbps} Mbps | ${dl_median} Mbps | ${dl_p25} Mbps | ${dl_p75} Mbps |"
        echo "| 上传 | ${ul_mbps} Mbps | ${ul_median} Mbps | ${ul_p25} Mbps | ${ul_p75} Mbps |"
        echo ""
        echo "### 延迟测试"
        echo "| 类型 | 平均 | 抖动 | 丢包 |"
        echo "|:---|---:|---:|---:|"
        echo "| 空闲延迟 | ${idle_avg} ms | ${idle_jitter} ms | ${idle_loss}% |"
        echo "| 负载延迟 (下载) | ${loaded_dl_avg} ms | ${loaded_dl_jitter} ms | - |"
        echo "| 负载延迟 (上传) | ${loaded_ul_avg} ms | ${loaded_ul_jitter} ms | - |"
        echo ""
    } >> "$REPORT_FILE"

    # 清理 cloudflare-speed-cli 生成的本地数据
    rm -rf "$HOME/.local/share/cloudflare-speed-cli" 2>/dev/null

    info "  └─ Cloudflare Speedtest 完成"
}

run_apple_speedtest() {
    log "开始 Apple CDN Speedtest..."

    if [ "$INETSPEED_BIN" == "false" ] || [ -z "$INETSPEED_BIN" ]; then
        warn "  └─ iNetSpeed-CLI 未安装或下载失败，跳过"
        return
    fi

    if [ ! -x "$INETSPEED_BIN" ] && ! command -v "$INETSPEED_BIN" >/dev/null 2>&1; then
        warn "  └─ iNetSpeed-CLI ($INETSPEED_BIN) 不可执行，跳过"
        return
    fi

    echo "  ├─ 正在测试 Apple CDN 速度..."

    # 非 TTY 模式下自动选择第一个节点，用 echo "" 发送回车确认
    local raw_output
    raw_output=$(echo "" | "$INETSPEED_BIN" 2>&1)

    if [ -z "$raw_output" ]; then
        warn "  └─ Apple CDN Speedtest 失败: 无输出"
        return
    fi

    # 清理 ANSI 转义序列
    local clean_output
    clean_output=$(echo "$raw_output" | sed 's/\x1b\[[0-9;]*m//g' | sed 's/\r//g')

    # 解析节点信息
    local endpoint=$(echo "$clean_output" | grep -oP 'Selected endpoint: \K[0-9.]+' | head -n1)
    local endpoint_loc=$(echo "$clean_output" | grep -oP 'Selected endpoint: [0-9.]+ \(\K[^)]+' | head -n1)
    [ -z "$endpoint" ] && endpoint=$(echo "$clean_output" | grep -oP 'Host: \K\S+' | head -n1)

    # 解析空闲延迟 (header 和数据行之间隔了 [+] Samples: 行，需要 -A3)
    local idle_line=$(echo "$clean_output" | grep -A3 'Idle Latency' | grep -- '->' | head -n1)
    local idle_latency=$(echo "$idle_line" | grep -oP '[0-9.]+ ms median' | grep -oP '[0-9.]+' | head -n1)
    local idle_jitter=$(echo "$idle_line" | grep -oP 'jitter [0-9.]+ ms' | grep -oP '[0-9.]+' | head -n1)
    local idle_min=$(echo "$idle_line" | grep -oP 'min [0-9.]+' | grep -oP '[0-9.]+' | head -n1)
    local idle_avg=$(echo "$idle_line" | grep -oP 'avg [0-9.]+' | grep -oP '[0-9.]+' | head -n1)
    local idle_max=$(echo "$idle_line" | grep -oP 'max [0-9.]+' | grep -oP '[0-9.]+' | head -n1)

    # 解析速度 - 匹配 "-> NNN Mbps" 汇总行（非 TTY 模式箭头是 -> 不是 ➜）
    # 下载单线程
    local dl_single=$(echo "$clean_output" | sed -n '/Download (single/,/Loaded latency/p' | grep -oP -- '->\s+\K[0-9.]+ [A-Za-z]+' | head -n1)
    local dl_single_loaded=$(echo "$clean_output" | sed -n '/Download (single/,/Download (multi/p' | grep -oP 'Loaded latency: \K[0-9.]+ ms' | head -n1)

    # 下载多线程
    local dl_multi=$(echo "$clean_output" | sed -n '/Download (multi/,/Loaded latency/p' | grep -oP -- '->\s+\K[0-9.]+ [A-Za-z]+' | head -n1)
    local dl_multi_loaded=$(echo "$clean_output" | sed -n '/Download (multi/,/Upload (single/p' | grep -oP 'Loaded latency: \K[0-9.]+ ms' | head -n1)

    # 上传单线程
    local ul_single=$(echo "$clean_output" | sed -n '/Upload (single/,/Loaded latency/p' | grep -oP -- '->\s+\K[0-9.]+ [A-Za-z]+' | head -n1)
    local ul_single_loaded=$(echo "$clean_output" | sed -n '/Upload (single/,/Upload (multi/p' | grep -oP 'Loaded latency: \K[0-9.]+ ms' | head -n1)

    # 上传多线程
    local ul_multi=$(echo "$clean_output" | sed -n '/Upload (multi/,/Summary/p' | grep -oP -- '->\s+\K[0-9.]+ [A-Za-z]+' | head -n1)
    local ul_multi_loaded=$(echo "$clean_output" | sed -n '/Upload (multi/,/Summary/p' | grep -oP 'Loaded latency: \K[0-9.]+ ms' | head -n1)

    # 解析数据用量
    local data_used=$(echo "$clean_output" | grep -oP 'Data Used:\s+\K[0-9.]+ [A-Za-z]+' | head -n1)

    # 控制台输出
    echo "  │  ├─ 节点: ${endpoint:-N/A} (${endpoint_loc:-N/A})"
    echo "  │  ├─ 下载: ${dl_single:-N/A} (单线程) / ${dl_multi:-N/A} (多线程)"
    echo "  │  ├─ 上传: ${ul_single:-N/A} (单线程) / ${ul_multi:-N/A} (多线程)"
    echo "  │  └─ 延迟: ${idle_latency:-N/A} ms (抖动: ${idle_jitter:-N/A} ms)"

    # === 写入报告 ===
    {
        echo "## Apple CDN Speedtest"
        echo "测试节点: ${endpoint:-N/A} (${endpoint_loc:-N/A})"
        echo ""
        echo "### 速度测试"
        echo "| 方向 | 单线程 | 多线程 | 负载延迟 (单) | 负载延迟 (多) |"
        echo "|:---|---:|---:|---:|---:|"
        echo "| 下载 | ${dl_single:-N/A} | ${dl_multi:-N/A} | ${dl_single_loaded:-N/A} | ${dl_multi_loaded:-N/A} |"
        echo "| 上传 | ${ul_single:-N/A} | ${ul_multi:-N/A} | ${ul_single_loaded:-N/A} | ${ul_multi_loaded:-N/A} |"
        echo ""
        echo "### 延迟测试"
        echo "| 指标 | 值 |"
        echo "|:---|---:|"
        echo "| 空闲延迟 (中位数) | ${idle_latency:-N/A} ms |"
        echo "| 空闲延迟 (最小/平均/最大) | ${idle_min:-N/A} / ${idle_avg:-N/A} / ${idle_max:-N/A} ms |"
        echo "| 空闲抖动 | ${idle_jitter:-N/A} ms |"
        echo "| 数据用量 | ${data_used:-N/A} |"
        echo ""
    } >> "$REPORT_FILE"

    info "  └─ Apple CDN Speedtest 完成"
}

# =========================
# 服务解锁测试
# =========================
run_stream_test() {
    log "开始服务解锁测试..."

    # 检查网络可用性
    if [ "$HAS_V4" != "true" ] && [ "$HAS_V6" != "true" ]; then
        warn "  └─ 无可用网络，跳过服务解锁测试"
        return
    fi

    # 从之前收集的网络信息中提取国家代码
    local country_code=""
    if [ "$HAS_V4" = "true" ] && [ -n "$NET_V4_LOC" ]; then
        country_code=$(echo "$NET_V4_LOC" | awk -F', ' '{print $NF}' | xargs)
    elif [ "$HAS_V6" = "true" ] && [ -n "$NET_V6_LOC" ]; then
        country_code=$(echo "$NET_V6_LOC" | awk -F', ' '{print $NF}' | xargs)
    fi

    # 1-stream RegionRestrictionCheck 的区域 ID 定义:
    # 0=只进行跨国平台，1=台湾，2=香港，3=日本，4=北美，5=南美
    # 6=欧洲，7=大洋洲，8=韩国，9=东南亚，10=AI平台，11=非洲，99=体育直播

    local region_id="0"  # 默认仅跨国平台
    local region_name="仅跨国平台"
    local detected_region_id=""
    local detected_region_name=""

    # 根据国家代码映射到测试区域
    case "$country_code" in
        # 台湾
        TW) detected_region_id="1"; detected_region_name="跨国平台+台湾平台" ;;
        # 香港
        HK) detected_region_id="2"; detected_region_name="跨国平台+香港平台" ;;
        # 日本
        JP) detected_region_id="3"; detected_region_name="跨国平台+日本平台" ;;
        # 北美
        US|CA|MX) detected_region_id="4"; detected_region_name="跨国平台+北美平台" ;;
        # 南美
        BR|AR|CL|CO|PE|VE|EC|BO|UY|PY|GY|SR) detected_region_id="5"; detected_region_name="跨国平台+南美平台" ;;
        # 欧洲
        GB|DE|FR|IT|ES|NL|BE|AT|CH|PL|CZ|PT|SE|NO|DK|FI|IE|RO|HU|GR|RU|UA|BY) detected_region_id="6"; detected_region_name="跨国平台+欧洲平台" ;;
        # 大洋洲
        AU|NZ|FJ|PG|NC|PF) detected_region_id="7"; detected_region_name="跨国平台+大洋洲平台" ;;
        # 韩国
        KR) detected_region_id="8"; detected_region_name="跨国平台+韩国平台" ;;
        # 东南亚
        SG|MY|TH|VN|ID|PH|MM|KH|LA|BN) detected_region_id="9"; detected_region_name="跨国平台+东南亚平台" ;;
        # 非洲
        ZA|EG|NG|KE|MA|TN|GH|TZ|UG|ZW|ET) detected_region_id="11"; detected_region_name="跨国平台+非洲平台" ;;
        # 其他 -> 归类到跨国平台
        *) detected_region_id=""; detected_region_name="" ;;
    esac

    echo "  ├─ 检测到服务器位置: ${country_code:-未知}"

    # 如果检测到了对应的地区，询问用户选择
    if [ -n "$detected_region_id" ]; then
        echo "  ├─ 匹配测试区域: $detected_region_name (ID: $detected_region_id)"
        echo -e "  ├─ ${YELLOW}请选择测试模式:${NC}"
        echo "  │  ├─ [1] $detected_region_name (默认)"
        echo "  │  ├─ [0] 仅跨国平台检测"
        echo -n -e "  │  ├─ ${YELLOW}请输入选项 (3 秒后自动选择模式 1): ${NC}"
        read -t 3 -r user_choice </dev/tty 2>/dev/null || { user_choice="1"; echo ""; }

        case "$user_choice" in
            0)
                region_id="0"
                region_name="仅跨国平台"
                ;;
            *)
                region_id="$detected_region_id"
                region_name="$detected_region_name"
                ;;
        esac
    else
        echo "  ├─ 未匹配到特定区域，将执行仅跨国平台检测"
        region_id="0"
        region_name="仅跨国平台"
    fi

    echo "  │  └─ 选择测试区域: $region_name (ID: $region_id)"

    # 调用外部流媒体测试脚本
    # -R: 指定测试区域
    # -M 4: 仅使用 IPv4
    # -M 6: 仅使用 IPv6

    # 下载并执行流媒体测试脚本，捕获输出
    local stream_output=""
    local stream_script_url="https://github.com/1-stream/RegionRestrictionCheck/raw/main/check.sh"
    local stream_tmp_file="$TMP_DIR/stream_output.txt"

    # 下载脚本到临时文件
    echo -n "  ├─ 正在下载测试脚本..."
    local stream_script_file="$TMP_DIR/check_stream.sh"
    if ! retry_download "$stream_script_file" "$stream_script_url" "测试脚本"; then
        echo -e " ${RED}失败${NC}"
        warn "  └─ 服务解锁测试失败：无法下载测试脚本"
        return
    fi
    # 将脚本中的 python json.tool 替换为 jq（更轻量，脚本已有 jq 依赖）
    sed -i -E 's/python3?  *-m json\.tool( 2>\/dev\/null)?/jq \./g' "$stream_script_file"
    echo -e " ${GREEN}完成${NC}"
    chmod +x "$stream_script_file"

    # 定义执行单次测试的函数
    run_single_stream_test() {
        local test_mode="$1"
        local mode_name="$2"
        local output_file="$3"

        # 启动后台进度指示器
        echo -n "  ├─ 正在执行 ${mode_name} 测试 "
        local spinner_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        SPINNER_PID=""
        (
            local i=0
            local start_time=$(date +%s)
            while true; do
                local elapsed=$(($(date +%s) - start_time))
                local mins=$((elapsed / 60))
                local secs=$((elapsed % 60))
                printf "\r  ├─ 正在执行 ${mode_name} 测试 ${spinner_chars:i++%10:1} [%02d:%02d]" "$mins" "$secs"
                sleep 0.2
            done
        ) &
        SPINNER_PID=$!

        # 执行测试 (新版 1-stream 脚本不支持 -R 参数指定区域，需要通过管道输入)
        if command -v script >/dev/null 2>&1; then
            TERM=xterm-256color script -q -c "echo '$region_id' | bash '$stream_script_file' -M '$test_mode'" "$output_file" >/dev/null 2>&1
        else
            echo "$region_id" | bash "$stream_script_file" -M "$test_mode" > "$output_file" 2>&1
        fi

        # 停止进度指示器
        kill $SPINNER_PID 2>/dev/null
        wait $SPINNER_PID 2>/dev/null
        SPINNER_PID=""

        if [ -f "$output_file" ] && [ -s "$output_file" ]; then
            echo -e "\r  ├─ ${mode_name} 测试完成 ${GREEN}✓${NC}              "
            return 0
        else
            echo -e "\r  ├─ ${mode_name} 测试失败 ${RED}✗${NC}              "
            return 1
        fi
    }

    # 分开测试 IPv4 和 IPv6
    local stream_output_v4=""
    local stream_output_v6=""
    local stream_output_ai_v4=""
    local stream_output_ai_v6=""
    local stream_tmp_v4="$TMP_DIR/stream_v4.txt"
    local stream_tmp_v6="$TMP_DIR/stream_v6.txt"
    local stream_tmp_ai_v4="$TMP_DIR/stream_ai_v4.txt"
    local stream_tmp_ai_v6="$TMP_DIR/stream_ai_v6.txt"
    local ai_region_id="10"

    # 执行单个 IP 版本的所有测试（流媒体 + AIGC）
    run_combined_test() {
        local test_mode="$1"
        local mode_name="$2"
        local stream_file="$3"
        local ai_file="$4"
        local region="$5"
        local ai_region="$6"

        # 启动后台进度指示器
        echo -n "  ├─ 正在执行 ${mode_name} 检测 "
        local spinner_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        SPINNER_PID=""
        (
            local i=0
            local start_time=$(date +%s)
            while true; do
                local elapsed=$(($(date +%s) - start_time))
                local mins=$((elapsed / 60))
                local secs=$((elapsed % 60))
                printf "\r  ├─ 正在执行 ${mode_name} 检测 ${spinner_chars:i++%10:1} [%02d:%02d]" "$mins" "$secs"
                sleep 0.2
            done
        ) &
        SPINNER_PID=$!

        # 执行流媒体测试
        if command -v script >/dev/null 2>&1; then
            TERM=xterm-256color script -q -c "echo '$region' | bash '$stream_script_file' -M '$test_mode'" "$stream_file" >/dev/null 2>&1
        else
            echo "$region" | bash "$stream_script_file" -M "$test_mode" > "$stream_file" 2>&1
        fi

        # 执行 AIGC 测试
        if command -v script >/dev/null 2>&1; then
            TERM=xterm-256color script -q -c "echo '$ai_region' | bash '$stream_script_file' -M '$test_mode'" "$ai_file" >/dev/null 2>&1
        else
            echo "$ai_region" | bash "$stream_script_file" -M "$test_mode" > "$ai_file" 2>&1
        fi

        # 停止进度指示器
        kill $SPINNER_PID 2>/dev/null
        wait $SPINNER_PID 2>/dev/null
        SPINNER_PID=""

        # 检查结果
        local success=false
        if [ -f "$stream_file" ] && [ -s "$stream_file" ]; then
            success=true
        fi
        if [ -f "$ai_file" ] && [ -s "$ai_file" ]; then
            success=true
        fi

        if [ "$success" = "true" ]; then
            echo -e "\r  ├─ ${mode_name} 检测完成 ${GREEN}✓${NC}              "
            return 0
        else
            echo -e "\r  ├─ ${mode_name} 检测失败 ${RED}✗${NC}              "
            return 1
        fi
    }

    # IPv4 测试
    if [ "$HAS_V4" = "true" ]; then
        run_combined_test "4" "IPv4" "$stream_tmp_v4" "$stream_tmp_ai_v4" "$region_id" "$ai_region_id"
        [ -f "$stream_tmp_v4" ] && stream_output_v4=$(cat "$stream_tmp_v4" 2>/dev/null)
        [ -f "$stream_tmp_ai_v4" ] && stream_output_ai_v4=$(cat "$stream_tmp_ai_v4" 2>/dev/null)
        rm -f "$stream_tmp_v4" "$stream_tmp_ai_v4"
    fi

    # IPv6 测试
    if [ "$HAS_V6" = "true" ]; then
        run_combined_test "6" "IPv6" "$stream_tmp_v6" "$stream_tmp_ai_v6" "$region_id" "$ai_region_id"
        [ -f "$stream_tmp_v6" ] && stream_output_v6=$(cat "$stream_tmp_v6" 2>/dev/null)
        [ -f "$stream_tmp_ai_v6" ] && stream_output_ai_v6=$(cat "$stream_tmp_ai_v6" 2>/dev/null)
        rm -f "$stream_tmp_v6" "$stream_tmp_ai_v6"
    elif [ "$SKIP_V6" != "true" ]; then
        # 只有当用户没有指定 -4 参数时才提示跳过
        echo "  ├─ IPv6 检测跳过 (IPv6: N/A)"
    fi

    # 清理脚本文件
    rm -f "$stream_script_file"

    # 合并输出
    stream_output=""
    if [ -n "$stream_output_v4" ]; then
        stream_output="${stream_output_v4}"
    fi
    if [ -n "$stream_output_v6" ]; then
        stream_output="${stream_output}
${stream_output_v6}"
    fi

    if [ -z "$stream_output" ]; then
        warn "  └─ 服务解锁测试失败：无法获取测试结果"
        return
    fi

    info "  └─ 服务解锁测试完成"

    # === Streaming Report ===
    # 解析流媒体测试结果并转换为表格
    parse_stream_to_table() {
        local output="$1"
        local ip_version="$2"

        # 清理 ANSI 颜色代码和控制字符
        local cleaned=$(echo "$output" | \
            sed 's/\x1b\[[0-9;]*m//g' | \
            sed 's/\x1b\[H\x1b\[2J//g' | \
            sed 's/\x1b\[?25[hl]//g' | \
            tr -d '\r')

        # 提取当前 IP 版本的测试结果
        local in_section="false"
        local current_category=""
        local last_category=""
        local results=""

        while IFS= read -r line; do
            # 检测 IP 版本测试开始
            if echo "$line" | grep -q "正在测试.*$ip_version"; then
                in_section="true"
                continue
            fi

            # 检测下一个 IP 版本测试开始（结束当前）
            if [ "$in_section" = "true" ] && echo "$line" | grep -q "正在测试.*IPv[46]"; then
                break
            fi

            # 在当前 IP 版本区域内
            if [ "$in_section" = "true" ]; then
                # 匹配区域标题 ===[ xxx ]=== 或 ============[ xxx ]============
                if echo "$line" | grep -qE '=+\[.*\]=+'; then
                    current_category=$(echo "$line" | sed 's/=//g' | sed 's/\[//g' | sed 's/\]//g' | xargs)
                    # 输出分类标题行（用 CATEGORY: 前缀标记）
                    results="${results}CATEGORY:${current_category}|\n"
                    last_category="$current_category"
                    continue
                fi

                # 匹配子分类 ---GB--- ---FR--- 等
                if echo "$line" | grep -qE '^-{3}[A-Za-z]+-{3}$'; then
                    current_category=$(echo "$line" | sed 's/-//g')
                    # 输出子分类标题行（用 SUBCATEGORY: 前缀标记）
                    results="${results}SUBCATEGORY:${current_category}|\n"
                    continue
                fi

                # 匹配测试结果行（含Tab或多个空格和冒号）
                # 排除: 脚本信息行、jq 错误输出、parse error 解析错误
                if echo "$line" | grep -qE '^\s*[A-Za-z0-9+() -]+:\s+' && \
                   ! echo "$line" | grep -qE '脚本适配|您的网络|测试时间|版本|运行次数|t\.me|github|网站|详情' && \
                   ! echo "$line" | grep -qiE '^\s*(jq\s*:|parse error|Invalid)'; then
                    # 解析服务名称和状态
                    # 状态通常是 Yes/No/Failed 开头，找最后一个 ":\s+(Yes|No|Failed|Region|City|JPY|JP|...)" 作为分隔点
                    local trimmed=$(echo "$line" | sed 's/^\s*//')
                    # 使用 sed 匹配最后一个 ":\s+状态" 模式
                    if echo "$trimmed" | grep -qE ':\s+(Yes|No|Failed|[A-Z]{2,3}(\s|$)|Region|City|Country)'; then
                        # 找到最后一个 ": " 后跟状态关键词的位置，用 awk 处理
                        local service=$(echo "$trimmed" | sed -E 's/:\s+(Yes|No|Failed).*$//' | sed -E 's/:\s+[A-Z]{2,3}(\s|$).*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                        local status=$(echo "$trimmed" | grep -oE '(Yes|No|Failed).*$' | head -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                        # 如果 status 为空，尝试其他模式
                        if [ -z "$status" ]; then
                            status=$(echo "$trimmed" | sed -E 's/.*:\s+//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                            service=$(echo "$trimmed" | sed -E 's/:\s+[^:]+$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                        fi
                    else
                        # 回退到原来的简单分割逻辑
                        local service=$(echo "$trimmed" | cut -d':' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                        local status=$(echo "$trimmed" | cut -d':' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                    fi

                    # 直接使用原始状态，不做转换
                    results="${results}${service}|${status}\n"
                fi
            fi
        done <<< "$cleaned"

        echo -e "$results"
    }

    # 自检:原始输出非空但解析不到任何服务行 -> 上游格式可能已变
    local _parsed_lines=0
    if [ -n "$stream_output_v4" ]; then
        _parsed_lines=$(( _parsed_lines + $(parse_stream_to_table "$stream_output_v4" "IPv4" | grep -Ev '^(CATEGORY:|SUBCATEGORY:|$)' | grep -c '|') ))
    fi
    if [ -n "$stream_output_v6" ]; then
        _parsed_lines=$(( _parsed_lines + $(parse_stream_to_table "$stream_output_v6" "IPv6" | grep -Ev '^(CATEGORY:|SUBCATEGORY:|$)' | grep -c '|') ))
    fi
    if [ "$_parsed_lines" -eq 0 ]; then
        warn "  ⚠️ 服务解锁:已获取上游输出但未解析到任何结果,上游 check.sh 格式可能已变化(报告该节将为空)。"
    fi

    {
        echo "## 服务解锁测试"
        echo ""
        echo "测试区域: **$region_name**"
        echo ""

        # 定义输出单个分类的函数
        output_stream_category() {
            local output="$1"
            local ip_version="$2"

            local current_table_started=false

            parse_stream_to_table "$output" "$ip_version" | while IFS='|' read -r service status; do
                if [ -n "$service" ]; then
                    if [[ "$service" == CATEGORY:* ]]; then
                        local cat_name="${service#CATEGORY:}"
                        if [ "$current_table_started" = "true" ]; then
                            echo ""
                        fi
                        echo "#### $cat_name"
                        echo ""
                        echo "| 服务 | 状态 |"
                        echo "| :--- | :--- |"
                        current_table_started=true
                    elif [[ "$service" == SUBCATEGORY:* ]]; then
                        local subcat_name="${service#SUBCATEGORY:}"
                        echo "| **── $subcat_name ──** | |"
                    else
                        if [ "$current_table_started" != "true" ]; then
                            echo "| 服务 | 状态 |"
                            echo "| :--- | :--- |"
                            current_table_started=true
                        fi
                        echo "| $service | $status |"
                    fi
                fi
            done
        }

        # 定义输出 AIGC 的函数（无分类标题）
        output_aigc_section() {
            local output="$1"
            local ip_version="$2"

            echo "#### AIGC"
            echo ""
            echo "| 服务 | 状态 |"
            echo "| :--- | :--- |"

            parse_stream_to_table "$output" "$ip_version" | while IFS='|' read -r service status; do
                if [ -n "$service" ]; then
                    # 跳过分类标题
                    if [[ "$service" != CATEGORY:* ]] && [[ "$service" != SUBCATEGORY:* ]]; then
                        # 跳过 Microsoft Copilot
                        [[ "$service" == *"Microsoft Copilot"* ]] && continue
                        echo "| $service | $status |"
                    fi
                fi
            done
            echo ""
        }

        # IPv4 结果
        if [ -n "$stream_output_v4" ] || [ -n "$stream_output_ai_v4" ]; then
            echo "### IPv4"
            echo ""

            # 先输出 AIGC
            if [ -n "$stream_output_ai_v4" ]; then
                output_aigc_section "$stream_output_ai_v4" "IPv4"
            fi

            # 再输出其他流媒体分类
            if [ -n "$stream_output_v4" ]; then
                output_stream_category "$stream_output_v4" "IPv4"
            fi
            echo ""
        fi

        # IPv6 结果
        if [ -n "$stream_output_v6" ] || [ -n "$stream_output_ai_v6" ]; then
            echo "### IPv6"
            echo ""

            # 先输出 AIGC
            if [ -n "$stream_output_ai_v6" ]; then
                output_aigc_section "$stream_output_ai_v6" "IPv6"
            fi

            # 再输出其他流媒体分类
            if [ -n "$stream_output_v6" ]; then
                output_stream_category "$stream_output_v6" "IPv6"
            fi
            echo ""
        fi

    } >> "$REPORT_FILE"
}

# =========================
# Traceroute
# =========================
create_ix_map() {
    local map_url="https://raw.githubusercontent.com/Lowendaff/linux_bench/main/utils/nf_ix_map.txt"
    # 直接下载并覆盖，带重试机制
    if ! retry_download "$TMP_DIR/ix_ip_map.txt" "$map_url" "IX Map" "--connect-timeout 5 --max-time 10"; then
        warn "  Failed to download Netflix IX map. Using empty map."
        echo "" > "$TMP_DIR/ix_ip_map.txt"
    fi
}

# 运营商名称规范化函数
# 参数: $1 = 原始运营商名称
# 返回: 规范化后的运营商名称（通过echo）
normalize_isp_name() {
    local isp="$1"
    local isp_lower=$(echo "$isp" | tr '[:upper:]' '[:lower:]')

    # === 1. 中国运营商海外分支（必须优先匹配）===
    # 联通海外
    [[ "$isp" == *"联通"*"香港"* || "$isp" == *"联通（香港）"* || "$isp_lower" == *"unicom"*"hong kong"* ]] && { echo "中国联通（香港）"; return; }
    [[ "$isp_lower" == *"chinaunicomglobal"* || "$isp_lower" == *"china unicom global"* ]] && { echo "中国联通（国际）"; return; }
    # 电信海外
    [[ "$isp_lower" == *"ctgnet"* || "$isp_lower" == *"china telecom global"* ]] && { echo "中国电信（国际）"; return; }
    # 移动海外 (CMI = China Mobile International)
    [[ "$isp" == *"移动"*"CMI"* || "$isp" == *"移动 CMI"* || "$isp_lower" == *"cmi.chinamobile"* || "$isp_lower" == *"cmi-int"* || ( "$isp_lower" == *"cmi"* && "$isp_lower" == *"mobile"* ) ]] && { echo "中国移动（国际）"; return; }

    # === 2. 港澳运营商 ===
    [[ "$isp" == *"电讯盈科"* || "$isp_lower" == *"pccw"* ]] && { echo "PCCW"; return; }
    [[ "$isp" == *"和记"* || "$isp_lower" == *"hgc"* || "$isp_lower" == *"hutchison"* ]] && { echo "HGC"; return; }
    # 中国移动香港变体
    [[ "$isp" == *"中国移动"*"香港"* || "$isp" == *"中国移动（香港）"* ]] && { echo "中国移动（香港）"; return; }
    [[ "$isp_lower" == *"cmi"* && "$isp_lower" == *"hong kong"* ]] && { echo "中国移动（香港）"; return; }

    # === 3. 中国三大运营商（国内，通配符匹配）===
    [[ "$isp" == *"联通"* || "$isp_lower" == *"unicom"* || "$isp_lower" == *"bbn.com.cn"* || "$isp_lower" == *"cuii"* ]] && [[ "$isp" != *"中国联通"* ]] && { echo "中国联通"; return; }
    [[ "$isp" == *"电信"* || "$isp_lower" == *"chinatelecom"* || "$isp_lower" == *"189.cn"* || "$isp_lower" == *"cn2"* || ( "$isp_lower" == *"telecom"* && "$isp_lower" == *"china"* ) ]] && [[ "$isp" != *"中国电信"* ]] && { echo "中国电信"; return; }
    [[ "$isp" == *"移动"* || "$isp_lower" == *"chinamobile"* || "$isp_lower" == *"10086"* || ( "$isp_lower" == *"mobile"* && "$isp_lower" == *"china"* ) ]] && [[ "$isp" != *"中国移动"* ]] && { echo "中国移动"; return; }
    [[ "$isp" == *"地面通"* ]] && { echo "中国电信"; return; }
    # 清理中国运营商特殊后缀
    [[ "$isp" == "中国电信/骨干网" ]] && { echo "中国电信"; return; }
    [[ "$isp" == "中国电信/CN2" ]] && { echo "中国电信/CN2"; return; }
    [[ "$isp" == "中国联通/骨干网" ]] && { echo "中国联通"; return; }
    # 中国移动国际统一格式
    [[ "$isp" == "中国移动国际" ]] && { echo "中国移动（国际）"; return; }

    # === 4. 国际运营商 ===
    [[ "$isp_lower" == *"google"* || "$isp" == *"谷歌"* ]] && { echo "Google"; return; }
    [[ "$isp_lower" == *"misaka"* ]] && { echo "Misaka"; return; }
    [[ "$isp_lower" == *"lumen"* || "$isp_lower" == *"level 3"* || "$isp_lower" == *"level3"* || "$isp" == *"世纪互联"* || "$isp" == *"流明"* ]] && { echo "Lumen"; return; }
    [[ "$isp_lower" == *"cogent"* || "$isp_lower" == *"psinet"* ]] && { echo "Cogent"; return; }
    [[ "$isp_lower" == *"zayo"* ]] && { echo "Zayo"; return; }
    [[ "$isp_lower" == *"joint transit"* ]] && { echo "Joint Transit"; return; }
    [[ "$isp_lower" == *"broadband hosting"* ]] && { echo "Broadband Hosting"; return; }
    [[ "$isp_lower" == *"pch"* ]] && { echo "PCH"; return; }
    [[ "$isp_lower" == *"myloc"* ]] && { echo "myLoc"; return; }
    [[ "$isp_lower" == *"wiit.cloud"* ]] && { echo "WIIT"; return; }
    [[ "$isp_lower" == *"lwlcom"* ]] && { echo "LWLcom"; return; }
    [[ "$isp_lower" == *"tinet"* || "$isp_lower" == *"gtt"* ]] && { echo "GTT"; return; }
    [[ "$isp_lower" == *"arelion"* ]] && { echo "Arelion"; return; }
    [[ "$isp_lower" == *"telia"* || "$isp" == *"特利亚"* ]] && { echo "Telia"; return; }
    [[ "$isp_lower" == "provider" ]] && { echo "Telia"; return; }
    [[ "$isp_lower" == *"sparkle"* || "$isp_lower" == *"sea-bone"* || "$isp_lower" == *"tisparkle"* ]] && { echo "Sparkle"; return; }
    [[ "$isp_lower" == *"orange"* || "$isp_lower" == *"france telecom"* || "$isp_lower" == *"oinis"* ]] && { echo "Orange"; return; }
    [[ "$isp_lower" == *"leaseweb"* ]] && { echo "Leaseweb"; return; }
    [[ "$isp_lower" == *"ntt"* || "$isp" == *"日本电报电话"* || "$isp" == *"恩梯梯"* ]] && { echo "NTT"; return; }
    [[ "$isp_lower" == *"tata"* || "$isp" == *"塔塔"* || "$isp_lower" == *"teleglobe"* || "$isp_lower" == *"customers access"* || "$isp_lower" == *"bb internal"* ]] && { echo "Tata"; return; }
    [[ "$isp_lower" == *"hurricane"* || "$isp_lower" == *"he.net"* ]] && { echo "HE"; return; }
    [[ "$isp_lower" == *"cdn77"* ]] && { echo "CDN77"; return; }
    [[ "$isp_lower" == *"readydedis"* ]] && { echo "ReadyDedis"; return; }
    [[ "$isp_lower" == *"host universal"* || "$isp_lower" == *"hostuniversal"* ]] && { echo "HostUniversal"; return; }
    [[ "$isp_lower" == *"retn"* ]] && { echo "RETN"; return; }
    [[ "$isp_lower" == *"equinix"* ]] && { echo "Equinix"; return; }
    [[ "$isp_lower" == *"ipxo"* ]] && { echo "IPXO"; return; }
    [[ "$isp_lower" == *"agis"* || "$isp_lower" == *"gsl networks"* || "$isp_lower" == *"globalsecurelayer"* || "$isp_lower" == *"streamline servers"* ]] && { echo "GSL"; return; }
    [[ "$isp_lower" == *"fastly"* ]] && { echo "Fastly"; return; }
    [[ "$isp_lower" == *"obenet"* || "$isp_lower" == *"obe.net"* || "$isp_lower" == *"obenetwork"* || "$isp_lower" == *"obe infrastructure"* ]] && { echo "Obenet"; return; }
    [[ "$isp_lower" == *"clouvider"* ]] && { echo "Clouvider"; return; }
    [[ "$isp_lower" == *"eranium"* ]] && { echo "Eranium"; return; }
    [[ "$isp_lower" == *"edgoo"* ]] && { echo "Edgoo"; return; }
    [[ "$isp_lower" == *"sprint"* ]] && { echo "Sprint"; return; }
    [[ "$isp_lower" == *"xtom"* ]] && { echo "xTom"; return; }
    [[ "$isp_lower" == *"airband"* ]] && { echo "Airband"; return; }
    [[ "$isp_lower" == *"pccw"* && "$isp" != "PCCW" ]] && { echo "PCCW"; return; }

    # === 5. 日本运营商 ===
    [[ "$isp_lower" == *"gmo"* || "$isp_lower" == *"internet.gmo"* ]] && { echo "GMO Internet"; return; }
    [[ "$isp_lower" == *"biglobe"* ]] && { echo "Biglobe"; return; }
    [[ "$isp_lower" == *"kddi"* || "$isp" == *"凯迪迪爱"* || "$isp" == *"日本凯迪迪爱"* || "$isp_lower" == *"dion"* ]] && { echo "KDDI"; return; }
    [[ "$isp_lower" == *"arteria"* || "$isp_lower" == *"arteria-net"* ]] && { echo "ARTERIA"; return; }
    [[ "$isp_lower" == *"softbank"* || "$isp" == *"软银"* ]] && { echo "SoftBank"; return; }
    [[ "$isp_lower" == *"ntt communications"* || "$isp_lower" == *"ntt com"* || "$isp_lower" == *"ocn"* ]] && { echo "NTT"; return; }
    [[ "$isp_lower" == *"iij"* || "$isp_lower" == *"internet initiative japan"* ]] && { echo "IIJ"; return; }
    [[ "$isp_lower" == *"sakura"* ]] && { echo "Sakura"; return; }
    [[ "$isp" == *"日本网络信息中心"* || "$isp_lower" == *"jpnic"* || "$isp_lower" == *"japan network information"* ]] && { echo "JPNIC"; return; }

    # === 6. 云厂商与服务商 ===
    [[ "$isp_lower" == *"amazon"* || "$isp" == *"亚马逊"* ]] && { echo "AWS"; return; }
    [[ "$isp_lower" == *"cloudflare"* ]] && { echo "Cloudflare"; return; }
    [[ "$isp_lower" == *"quad9"* ]] && { echo "Quad9"; return; }
    [[ "$isp_lower" == *"telegram"* ]] && { echo "Telegram"; return; }
    [[ "$isp_lower" == *"netflix"* ]] && { echo "Netflix"; return; }
    [[ "$isp_lower" == *"vultr"* || "$isp_lower" == *"constant.com"* || "$isp_lower" == *"as-vultr"* || "$isp_lower" == *"choopa"* ]] && { echo "Vultr"; return; }
    [[ "$isp_lower" == *"servers.com"* ]] && { echo "Servers.com"; return; }
    [[ "$isp_lower" == *"workonline"* ]] && { echo "Workonline"; return; }
    [[ "$isp_lower" == *"verio"* ]] && { echo "NTT"; return; }
    [[ "$isp_lower" == *"sg.gs"* ]] && { echo "SG.GS"; return; }
    [[ "$isp" == *"阿里云"* || "$isp_lower" == *"alibaba"* || "$isp_lower" == *"aliyun"* ]] && { echo "阿里云"; return; }
    [[ "$isp" == *"腾讯"* || "$isp_lower" == *"tencent"* ]] && { echo "腾讯云"; return; }
    [[ "$isp" == *"华为"* || "$isp_lower" == *"huawei"* || "$isp_lower" == *"hwclouds"* ]] && { echo "华为云"; return; }
    [[ "$isp" == *"优刻得"* || "$isp_lower" == *"ucloud"* ]] && { echo "优刻得"; return; }
    [[ "$isp" == *"百度"* || "$isp_lower" == *"baidu"* || "$isp_lower" == *"bce"* ]] && { echo "百度云"; return; }
    [[ "$isp" == *"京东"* || "$isp_lower" == *"jdcloud"* || "$isp_lower" == *"jd cloud"* ]] && { echo "京东云"; return; }
    [[ "$isp" == *"金山"* || "$isp_lower" == *"kingsoft"* || "$isp_lower" == *"ksyun"* ]] && { echo "金山云"; return; }
    [[ "$isp" == *"七牛"* || "$isp_lower" == *"qiniu"* ]] && { echo "七牛"; return; }
    [[ "$isp" == *"又拍"* || "$isp_lower" == *"upyun"* ]] && { echo "又拍云"; return; }
    [[ "$isp" == *"网宿"* || "$isp_lower" == *"wangsu"* || "$isp_lower" == *"chinanetcenter"* ]] && { echo "网宿"; return; }
    [[ "$isp_lower" == *"corenet"* ]] && { echo "CoreNet"; return; }
    [[ "$isp_lower" == *"mejiro"* ]] && { echo "Mejiro"; return; }
    [[ "$isp_lower" == *"nexthop"* ]] && { echo "NextHop"; return; }
    [[ "$isp_lower" == *"digitalocean"* || "$isp_lower" == *"digital ocean"* ]] && { echo "DigitalOcean"; return; }
    [[ "$isp_lower" == *"linode"* || "$isp_lower" == *"akamai"* ]] && { echo "Akamai"; return; }
    [[ "$isp_lower" == *"ovh"* ]] && { echo "OVH"; return; }
    [[ "$isp_lower" == *"hetzner"* ]] && { echo "Hetzner"; return; }
    [[ "$isp_lower" == *"scaleway"* || "$isp_lower" == *"iliad"* ]] && { echo "Scaleway"; return; }
    [[ "$isp_lower" == *"rackspace"* ]] && { echo "Rackspace"; return; }
    [[ "$isp_lower" == *"oracle"* ]] && { echo "Oracle"; return; }
    [[ "$isp_lower" == *"microsoft"* || "$isp_lower" == *"azure"* ]] && { echo "Azure"; return; }
    [[ "$isp_lower" == *"ibm"* || "$isp_lower" == *"softlayer"* ]] && { echo "IBM Cloud"; return; }
    [[ "$isp_lower" == *"verizon"* || "$isp_lower" == *"ans communications"* || "$isp_lower" == *"mci"* || "$isp" == *"威瑞森"* || "$isp" == *"MCI通信"* ]] && { echo "Verizon"; return; }
    [[ "$isp_lower" == *"att"* || "$isp_lower" == *"at&t"* ]] && { echo "AT&T"; return; }
    [[ "$isp_lower" == *"comcast"* ]] && { echo "Comcast"; return; }
    [[ "$isp_lower" == *"centurylink"* ]] && { echo "CenturyLink"; return; }
    [[ "$isp_lower" == *"charter"* || "$isp_lower" == *"spectrum"* ]] && { echo "Charter"; return; }
    [[ "$isp_lower" == *"singtel"* ]] && { echo "Singtel"; return; }
    [[ "$isp_lower" == *"starhub"* ]] && { echo "StarHub"; return; }
    [[ "$isp_lower" == *"m1 limited"* || "$isp_lower" == *"m1.com.sg"* ]] && { echo "M1"; return; }
    [[ "$isp_lower" == *"telstra"* ]] && { echo "Telstra"; return; }
    [[ "$isp_lower" == *"optus"* ]] && { echo "Optus"; return; }
    [[ "$isp_lower" == *"vodafone"* || "$isp" == *"沃达丰"* ]] && { echo "Vodafone"; return; }
    [[ "$isp_lower" == *"deutsche telekom"* || "$isp_lower" == *"dtag"* || "$isp_lower" == *"wholesale.telekom"* ]] && { echo "DTAG"; return; }
    [[ "$isp_lower" == *"british telecom"* || "$isp_lower" == *"bt.net"* ]] && { echo "BT"; return; }
    [[ "$isp_lower" == *"internet utilities"* ]] && { echo "Internet Utilities"; return; }
    [[ "$isp_lower" == *"telefonica"* || "$isp_lower" == *"movistar"* ]] && { echo "Telefonica"; return; }
    [[ "$isp_lower" == *"cht"* || "$isp" == *"中华电信"* || "$isp_lower" == *"hinet"* || "$isp_lower" == *"chunghwa"* ]] && { echo "中华电信"; return; }
    [[ "$isp_lower" == *"taiwan mobile"* || "$isp" == *"台湾大哥大"* ]] && { echo "台湾大哥大"; return; }
    [[ "$isp_lower" == *"fetnet"* || "$isp" == *"远传"* ]] && { echo "远传电信"; return; }
    [[ "$isp_lower" == *"kt corp"* || "$isp_lower" == *"korea telecom"* ]] && { echo "KT"; return; }
    [[ "$isp_lower" == *"sk broadband"* || "$isp_lower" == *"sk telecom"* ]] && { echo "SK"; return; }
    [[ "$isp_lower" == *"lg uplus"* || "$isp_lower" == *"lg u+"* ]] && { echo "LG U+"; return; }

    # === 7. 越南运营商 ===
    [[ "$isp_lower" == *"fpt"* || "$isp_lower" == *"fpt telecom"* ]] && { echo "FPT"; return; }
    [[ "$isp" == *"越南互联网络信息中心"* || "$isp_lower" == *"vnnic"* ]] && { echo "VNNIC"; return; }
    [[ "$isp_lower" == *"viettel"* ]] && { echo "Viettel"; return; }
    [[ "$isp_lower" == *"vnpt"* ]] && { echo "VNPT"; return; }
    [[ "$isp_lower" == *"mobifone"* ]] && { echo "MobiFone"; return; }

    # === 8. 欧洲托管与运营商 ===
    [[ "$isp_lower" == *"ghostnet"* ]] && { echo "GHOSTnet"; return; }
    [[ "$isp_lower" == *"tube-hosting"* || "$isp_lower" == *"ferdinand zink"* ]] && { echo "Tube-Hosting"; return; }
    [[ "$isp_lower" == *"skylink data center"* ]] && { echo "SkyLink DC"; return; }
    [[ "$isp_lower" == *"global network management"* ]] && { echo "GNM"; return; }
    [[ "$isp_lower" == *"ghita telekom"* ]] && { echo "Ghita Telekom"; return; }
    [[ "$isp_lower" == *"mss-povolzhe"* ]] && { echo "MSS-Povolzhe"; return; }
    [[ "$isp_lower" == *"contabo"* ]] && { echo "Contabo"; return; }
    [[ "$isp_lower" == *"netcup"* ]] && { echo "Netcup"; return; }
    [[ "$isp_lower" == *"ionos"* || "$isp_lower" == *"1&1"* ]] && { echo "IONOS"; return; }
    [[ "$isp_lower" == *"online.net"* || "$isp_lower" == *"online s.a.s"* ]] && { echo "Online.net"; return; }
    [[ "$isp_lower" == *"swisscom"* ]] && { echo "Swisscom"; return; }
    [[ "$isp_lower" == *"proximus"* || "$isp_lower" == *"belgacom"* ]] && { echo "Proximus"; return; }
    [[ "$isp_lower" == *"kpn"* ]] && { echo "KPN"; return; }
    [[ "$isp_lower" == *"telenor"* ]] && { echo "Telenor"; return; }
    [[ "$isp_lower" == *"tele2"* ]] && { echo "Tele2"; return; }
    [[ "$isp_lower" == *"free.fr"* || "$isp_lower" == *"freebox"* ]] && { echo "Free"; return; }
    [[ "$isp_lower" == *"sfr"* ]] && { echo "SFR"; return; }
    [[ "$isp_lower" == *"bouygues"* ]] && { echo "Bouygues"; return; }
    [[ "$isp_lower" == *"jose antonio vazquez quian"* || "$isp_lower" == *"andaina"* ]] && { echo "Andaina"; return; }
    [[ "$isp_lower" == *"r cable"* ]] && { echo "R Cable"; return; }
    [[ "$isp_lower" == *"i3d.net"* || "$isp_lower" == *"i3d net"* ]] && { echo "i3D.net"; return; }

    # === 9. 俄罗斯运营商 ===
    [[ "$isp_lower" == *"rostelecom"* ]] && { echo "Rostelecom"; return; }
    [[ "$isp_lower" == *"mts"* ]] && { echo "MTS"; return; }
    [[ "$isp_lower" == *"beeline"* || "$isp_lower" == *"vimpelcom"* ]] && { echo "Beeline"; return; }
    [[ "$isp_lower" == *"megafon"* ]] && { echo "MegaFon"; return; }
    [[ "$isp_lower" == *"yandex"* ]] && { echo "Yandex"; return; }
    [[ "$isp_lower" == *"mail.ru"* || "$isp_lower" == *"vk.com"* ]] && { echo "VK"; return; }

    # === 10. 其他亚洲运营商 ===
    [[ "$isp_lower" == *"pldt"* ]] && { echo "PLDT"; return; }
    [[ "$isp_lower" == *"globe"* && "$isp_lower" == *"philippines"* ]] && { echo "Globe"; return; }
    [[ "$isp_lower" == *"true"* && "$isp_lower" == *"thailand"* ]] && { echo "True"; return; }
    [[ "$isp_lower" == *"ais"* || "$isp_lower" == *"advanced info service"* ]] && { echo "AIS"; return; }
    [[ "$isp_lower" == *"telekom malaysia"* || "$isp_lower" == *"tm net"* ]] && { echo "TM"; return; }
    [[ "$isp_lower" == *"maxis"* ]] && { echo "Maxis"; return; }
    [[ "$isp_lower" == *"indosat"* ]] && { echo "Indosat"; return; }
    [[ "$isp_lower" == *"telkomsel"* ]] && { echo "Telkomsel"; return; }
    [[ "$isp_lower" == *"xl axiata"* ]] && { echo "XL Axiata"; return; }
    [[ "$isp_lower" == *"bsnl"* || "$isp_lower" == *"bharat sanchar"* ]] && { echo "BSNL"; return; }
    [[ "$isp_lower" == *"jio"* || "$isp_lower" == *"reliance"* ]] && { echo "Jio"; return; }
    [[ "$isp_lower" == *"airtel"* ]] && { echo "Airtel"; return; }

    # === 11. CDN 与托管服务 ===
    [[ "$isp_lower" == *"bunny"* || "$isp_lower" == *"bunnycdn"* ]] && { echo "BunnyCDN"; return; }
    [[ "$isp_lower" == *"stackpath"* || "$isp_lower" == *"highwinds"* ]] && { echo "StackPath"; return; }
    [[ "$isp_lower" == *"keycdn"* ]] && { echo "KeyCDN"; return; }
    [[ "$isp_lower" == *"sucuri"* ]] && { echo "Sucuri"; return; }
    [[ "$isp_lower" == *"incapsula"* || "$isp_lower" == *"imperva"* ]] && { echo "Imperva"; return; }
    [[ "$isp_lower" == *"ddos-guard"* ]] && { echo "DDoS-Guard"; return; }
    [[ "$isp_lower" == *"path.net"* ]] && { echo "Path.net"; return; }
    [[ "$isp_lower" == *"quadranet"* ]] && { echo "QuadraNet"; return; }
    [[ "$isp_lower" == *"psychz"* ]] && { echo "Psychz"; return; }
    [[ "$isp_lower" == *"colocrossing"* ]] && { echo "ColoCrossing"; return; }
    [[ "$isp_lower" == *"hostwinds"* ]] && { echo "Hostwinds"; return; }
    [[ "$isp_lower" == *"kamatera"* ]] && { echo "Kamatera"; return; }
    [[ "$isp_lower" == *"upcloud"* ]] && { echo "UpCloud"; return; }
    [[ "$isp_lower" == *"bandwagonhost"* || "$isp_lower" == *"buyvm"* || "$isp_lower" == *"frantech"* ]] && { echo "BuyVM"; return; }
    [[ "$isp_lower" == *"racknerd"* ]] && { echo "RackNerd"; return; }
    [[ "$isp_lower" == *"greencloud"* ]] && { echo "GreenCloud"; return; }
    [[ "$isp_lower" == *"dmit"* ]] && { echo "DMIT"; return; }
    [[ "$isp_lower" == *"hostdare"* ]] && { echo "HostDare"; return; }
    [[ "$isp_lower" == *"b2 net solutions"* || "$isp_lower" == *"servermania"* ]] && { echo "ServerMania"; return; }
    [[ "$isp_lower" == *"multacom"* ]] && { echo "Multacom"; return; }
    [[ "$isp_lower" == *"cnservers"* ]] && { echo "CNServers"; return; }
    [[ "$isp_lower" == *"terrahost"* ]] && { echo "Terrahost"; return; }
    [[ "$isp_lower" == *"hosteons"* ]] && { echo "Hosteons"; return; }
    [[ "$isp_lower" == *"cloudcone"* ]] && { echo "CloudCone"; return; }
    [[ "$isp_lower" == *"virtono"* ]] && { echo "Virtono"; return; }
    [[ "$isp_lower" == *"crowncloud"* ]] && { echo "CrownCloud"; return; }
    [[ "$isp_lower" == *"ssdnodes"* ]] && { echo "SSD Nodes"; return; }
    [[ "$isp_lower" == *"webtropia"* ]] && { echo "Netcup"; return; }
    [[ "$isp_lower" == *"melbicom"* ]] && { echo "Melbicom"; return; }

    # 如果没有匹配，返回原始值
    echo "$isp"
}

get_trace_targets() {
    local targets_url="https://raw.githubusercontent.com/Lowendaff/linux_bench/main/utils/trace_targets.txt"
    local targets_file="$TMP_DIR/trace_targets.txt"

    # 下载目标列表文件
    if ! retry_download "$targets_file" "$targets_url" "Trace Targets" "--connect-timeout 5 --max-time 15"; then
        warn "  Failed to download trace targets. Using fallback."
        # 如果下载失败，使用内置的基础目标
        cat << 'FALLBACK_EOF'
#GROUP:中国境内目标
北京电信 163 AS4134|ipv4.pek-4134.endpoint.nxtrace.org|ipv6.pek-4134.endpoint.nxtrace.org
北京联通 169 AS4837|ipv4.pek-4837.endpoint.nxtrace.org|ipv6.pek-4837.endpoint.nxtrace.org
北京移动 CMNET AS9808|ipv4.pek-9808.endpoint.nxtrace.org|ipv6.pek-9808.endpoint.nxtrace.org
上海电信 163 AS4134|ipv4.sha-4134.endpoint.nxtrace.org|ipv6.sha-4134.endpoint.nxtrace.org
上海联通 169 AS4837|ipv4.sha-4837.endpoint.nxtrace.org|ipv6.sha-4837.endpoint.nxtrace.org
上海移动 CMNET AS9808|ipv4.sha-9808.endpoint.nxtrace.org|ipv6.sha-9808.endpoint.nxtrace.org
广州电信 163 AS4134|ipv4.can-4134.endpoint.nxtrace.org|ipv6.can-4134.endpoint.nxtrace.org
广州联通 169 AS4837|ipv4.can-4837.endpoint.nxtrace.org|ipv6.can-4837.endpoint.nxtrace.org
广州移动 CMNET AS9808|ipv4.can-9808.endpoint.nxtrace.org|ipv6.can-9808.endpoint.nxtrace.org
FALLBACK_EOF
        return
    fi

    # 过滤掉纯注释行（保留 #GROUP: 分组标记），输出内容
    grep -v '^# ' "$targets_file" | grep -v '^$'
}

run_trace_test() {
    log "开始路由追踪测试..."

    # 调试信息
    # log "NextTrace Binary: $NEXTTRACE_BIN"

    if [ "$NEXTTRACE_BIN" == "false" ] || [ -z "$NEXTTRACE_BIN" ]; then
        warn "  └─ NextTrace 二进制未找到或下载失败，跳过";
        return;
    fi

    if [ ! -x "$NEXTTRACE_BIN" ] && ! command -v "$NEXTTRACE_BIN" >/dev/null 2>&1; then
        warn "  └─ NextTrace ($NEXTTRACE_BIN) 不可执行，跳过";
        return;
    fi

    create_ix_map

    echo "  ├─ 获取动态 CDN 节点..."
    local dynamic_targets=""
    if [ "$YTDLP_BIN" != "false" ] && { [ -x "$YTDLP_BIN" ] || command -v "$YTDLP_BIN" >/dev/null 2>&1; }; then
        # Try using "Me at the zoo" (jNQXAC9IVRw) and Android client to bypass bot detection
        local yt_video="https://www.youtube.com/watch?v=jNQXAC9IVRw"
        local yt_args="--no-warnings --extractor-args youtube:player_client=android -g"

        if [ "$HAS_V4" = "true" ]; then
            # Debug: Capture stderr to see why it fails
            local yt_err="$TMP_DIR/yt_v4.err"
            local v4=$("$YTDLP_BIN" $yt_args -4 "$yt_video" 2>"$yt_err" | head -n1 | awk -F/ '{print $3}')
            if [ -n "$v4" ]; then
                 dynamic_targets+="YouTube CDN (Dynamic)|$v4|"$'\n'
            else
                 # If failed, print warning with error content
                 local err_msg=$(cat "$yt_err" | tr '\n' ' ' | cut -c 1-100)
                 warn "  │  └─ YouTube (IPv4) 获取失败: $err_msg"
            fi
            rm -f "$yt_err"
        fi
        if [ "$HAS_V6" = "true" ]; then
            local yt_err="$TMP_DIR/yt_v6.err"
            local v6=$("$YTDLP_BIN" $yt_args -6 "$yt_video" 2>"$yt_err" | head -n1 | awk -F/ '{print $3}')
            if [ -n "$v6" ]; then
                dynamic_targets+="YouTube CDN (Dynamic)||$v6"$'\n'
            else
                 local err_msg=$(cat "$yt_err" | tr '\n' ' ' | cut -c 1-100)
                 warn "  │  └─ YouTube (IPv6) 获取失败: $err_msg"
            fi
            rm -f "$yt_err"
        fi
    else
        warn "  │  └─ yt-dlp 未安装或不可执行，跳过 YouTube 测试"
    fi
    # Netflix (Fast.com) - simplified
    local nf_api="https://api.fast.com/netflix/speedtest/v2?https=true&token=YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm&urlCount=5"
    if [ "$HAS_V4" = "true" ]; then
        local nf=$(curl -s -4 "$nf_api" 2>/dev/null | jq -r '.targets[]|select(.url|contains("ipv4"))|.url' 2>/dev/null | head -n1 | awk -F/ '{print $3}')
        [ -n "$nf" ] && dynamic_targets+="Netflix CDN (Dynamic)|$nf|"$'\n'
    fi
    if [ "$HAS_V6" = "true" ]; then
        local nf=$(curl -s -6 "$nf_api" 2>/dev/null | jq -r '.targets[]|select(.url|contains("ipv6"))|.url' 2>/dev/null | head -n1 | awk -F/ '{print $3}')
        [ -n "$nf" ] && dynamic_targets+="Netflix CDN (Dynamic)||$nf"$'\n'
    fi

    # 构建目标列表
    # 使用 process substitution 可能会在某些环境下有问题，改用字符串读取
    local raw_static=$(get_trace_targets)
    local all_targets=()
    local current_group=""

    # === Streaming Report ===
    {
        echo "## 路由追踪"
    } >> "$REPORT_FILE"

    # 首先添加公共服务目标（主要公共服务分组）
    local public_targets=""

    # 公共 DNS 服务
    if [ "$HAS_V4" = "true" ]; then
        public_targets+="Cloudflare DNS|1.1.1.1|"$'\n'
        public_targets+="Google DNS|8.8.8.8|"$'\n'
        public_targets+="Quad9 DNS|9.9.9.9|"$'\n'
    fi
    if [ "$HAS_V6" = "true" ]; then
        public_targets+="Cloudflare DNS||2606:4700:4700::1111"$'\n'
        public_targets+="Google DNS||2001:4860:4860::8888"$'\n'
        public_targets+="Quad9 DNS||2620:fe::fe"$'\n'
    fi

    # 添加动态 CDN 目标
    public_targets+="$dynamic_targets"

    if [ -n "$public_targets" ]; then
        all_targets+=("#GROUP:主要公共服务")
        while IFS= read -r line; do
            [ -n "$line" ] && all_targets+=("$line")
        done <<< "$public_targets"
    fi

    # 然后读取静态目标，处理分组标记
    while IFS= read -r line; do
        if [ -z "$line" ]; then
            continue
        elif [[ "$line" == "#GROUP:"* ]]; then
            # 从分组标记中提取组名
            current_group="${line#\#GROUP:}"
            # 将分组标记添加到目标数组中
            all_targets+=("#GROUP:$current_group")
        else
            all_targets+=("$line")
        fi
    done <<< "$raw_static"

    local idx=0
    local total=0
    # 计算非分组行的总数
    for entry in "${all_targets[@]}"; do
        [[ "$entry" != "#GROUP:"* ]] && total=$((total+1))
    done

    if [ "$total" -eq 0 ]; then
        warn "  └─ 未找到任何路由追踪目标"
        return
    fi

    # 使用 C-style loop 来灵活处理数组索引
    for ((i=0; i<${#all_targets[@]}; i++)); do
        entry="${all_targets[$i]}"
        [ -z "$entry" ] && continue

        # 处理分组标记
        if [[ "$entry" == "#GROUP:"* ]]; then
            local group_name="${entry#\#GROUP:}"
            # echo ""  <-- Remove empty line to keep tree compact
            echo "  ├── $group_name"
            # 在报告中添加分节标题
            {
                echo ""
                echo "### $group_name"
                echo ""
            } >> "$REPORT_FILE"

            # --- 计算该分组的总数 ---
            # 向后扫描直到下一个 #GROUP: 或数组结束
            total=0
            for ((j=i+1; j<${#all_targets[@]}; j++)); do
                local next_entry="${all_targets[$j]}"
                [[ "$next_entry" == "#GROUP:"* ]] && break
                if [ -n "$next_entry" ]; then
                    IFS='|' read -r _t_name _t_v4 _t_v6 <<< "$next_entry"
                    # Count IPv4 test if enabled and target exists
                    if [ -n "$_t_v4" ] && [ "$HAS_V4" = "true" ]; then total=$((total+1)); fi
                    # Count IPv6 test if enabled and target exists
                    if [ -n "$_t_v6" ] && [ "$HAS_V6" = "true" ]; then total=$((total+1)); fi
                fi
            done
            idx=0 # 重置组内序号

            continue
        fi

        # 如果一开始就没有 Group（防御性编程），先计算一个总数
        if [ "$total" -eq 0 ]; then
             for ((j=i; j<${#all_targets[@]}; j++)); do
                local next_entry="${all_targets[$j]}"
                [[ "$next_entry" == "#GROUP:"* ]] && break
                if [ -n "$next_entry" ]; then
                    IFS='|' read -r _t_name _t_v4 _t_v6 <<< "$next_entry"
                    if [ -n "$_t_v4" ] && [ "$HAS_V4" = "true" ]; then total=$((total+1)); fi
                    if [ -n "$_t_v6" ] && [ "$HAS_V6" = "true" ]; then total=$((total+1)); fi
                fi
            done
        fi

        # idx=$((idx+1))  <-- Remove here, increment inside test loop
        IFS='|' read -r name ipv4 ipv6 <<< "$entry"

        for mode in IPv4 IPv6; do
            local target=""
            [ "$mode" = "IPv4" ] && target="$ipv4"
            [ "$mode" = "IPv6" ] && target="$ipv6"

            # 只有当 目标存在 且 (是IPv4且有V4网 OR 是IPv6且有V6网) 时才测试
            if [ -n "$target" ] && { ([ "$mode" = "IPv4" ] && [ "$HAS_V4" = "true" ]) || ([ "$mode" = "IPv6" ] && [ "$HAS_V6" = "true" ]); }; then
                idx=$((idx+1))
                echo "  │  ├─ [$idx/$total] $name ($mode)..."
                local ipflag="-4"; [ "$mode" == "IPv6" ] && ipflag="-6"

                # 运行 nexttrace
                local raw_output=""
                local err_out=""
                # Capture stdout and stderr
                local err_file="$TMP_DIR/nt_err_$idx.log"
                raw_output=$("$NEXTTRACE_BIN" --json --tcp --psize 1400 $ipflag "$target" 2>"$err_file")
                err_out=$(cat "$err_file" 2>/dev/null)
                rm -f "$err_file"

                # Extract JSON part (remove everything before first '{')
                local json=$(echo "$raw_output" | sed 's/^[^{]*//')

                # Verify JSON
                if [ -z "$json" ] || ! echo "$json" | jq -e . >/dev/null 2>&1; then
                    echo "  │  │  └─ 失败: 无效输出"
                    # Debug: Show what we actually got
                    if [ -z "$raw_output" ]; then
                        echo "  │  │     (输出为空)"
                    else
                        local clean_out=$(echo "$raw_output" | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g')
                        echo "  │  │     (原始内容): ${clean_out:0:100}..."
                    fi

                    if [ -n "$err_out" ]; then
                        local clean_err=$(echo "$err_out" | sed 's/\x1b\[[0-9;]*m//g' | head -n 1)
                        echo "  │     (错误信息): $clean_err"
                    fi
                else
                    # Parse JSON Result and Build Table
                    # Hops wrapped in list: .[0] or simple array
                    # NextTrace 1.5.0 quirks: sometimes [[hop1, hop2]], sometimes [hop1, hop2]
                    local table="| 跳数 | IP | ASN | 位置 | 运营商 | 延迟 |\n"
                    table+="|---:|:---|:---|:---|:---|---:|\n"

                        # 根据 NORMALIZE_OUTPUT 构建不同的 jq 查询
                        local jq_loc_filter
                        if [ "$NORMALIZE_OUTPUT" = "true" ]; then
                            # 标准化输出：去掉"市""省""州"后缀
                            jq_loc_filter='map(select(. and . != "") | if (. | length) > 2 then gsub("市$|省$|州$"; "") else . end)'
                        else
                            # 默认原始输出：不处理后缀
                            jq_loc_filter='map(select(. and . != ""))'
                        fi

                        local rows=$(echo "$json" | jq -r '
                        # NextTrace JSON: { Hops: [ [probe0, probe1, probe2], ... ] }
                        .Hops | to_entries[] |
                        (.key + 1) as $hopnum |
                        .value as $probes |
                        # 选择第一个成功的探测，如果没有则取第一个
                        ([$probes[] | select(.Success == true)][0] // $probes[0] // {}) as $p |

                        # IP地址：如果为null或空，显示 "*"
                        (if $p.Address then ($p.Address.IP // "*") else "*" end) as $ip |

                        # ASN：只有非空字符串才显示
                        (if $p.Geo and ($p.Geo.asnumber // "") != "" then "AS" + $p.Geo.asnumber else "-" end) as $asn |

                        # 地理位置：国家 省份 城市（过滤空值、去重）
                        (if $p.Geo then
                            ([$p.Geo.country, $p.Geo.prov, $p.Geo.city] | '"$jq_loc_filter"' | reduce .[] as $x ([]; if . | index($x) then . else . + [$x] end) | join(" "))
                        else "" end) as $loc_raw |
                        (if $loc_raw == "" then "-" else $loc_raw end) as $loc |

                        # 运营商：优先 isp，其次 owner
                        (if $p.Geo then
                            (if ($p.Geo.isp // "") != "" then $p.Geo.isp
                             elif ($p.Geo.owner // "") != "" then $p.Geo.owner
                             else "-" end)
                        else "-" end) as $isp |

                        # 延迟：RTT 单位是纳秒，转换为毫秒
                        (if $p.RTT and $p.RTT > 0 then
                            (($p.RTT / 1000000 * 100 | floor) / 100 | tostring)
                        else "-" end) as $rtt |

                        [$hopnum, $ip, $asn, $loc, $isp, $rtt] | @tsv
                    ' 2>/dev/null)

                    if [ -n "$rows" ]; then
                        while IFS=$'\t' read -r ttl ip asn loc isp rtt; do
                            [ -z "$ip" ] && continue

                            # 当IP为"*"时显示"-"
                            [ "$ip" = "*" ] && ip="-"

                            # IX Check (只有IP不为"-"时才检查)
                            if [ "$ip" != "-" ]; then
                                local ix_name=$(grep -F "$ip " "$TMP_DIR/ix_ip_map.txt" 2>/dev/null | head -n1 | cut -d' ' -f2-)
                                [ -n "$ix_name" ] && isp="$isp [$ix_name]"
                            fi


                            # 运营商名称规范化（仅在标准化输出模式下）
                            if [ "$NORMALIZE_OUTPUT" = "true" ]; then
                                isp=$(normalize_isp_name "$isp")
                            fi
                            # RTT格式：有值时追加ms，无值时显示"-"
                            if [ "$rtt" != "-" ] && [ -n "$rtt" ]; then
                                rtt_display="$rtt ms"
                            else
                                rtt_display="-"
                            fi
                            table+="| $ttl | $ip | $asn | $loc | $isp | $rtt_display |\n"
                        done <<< "$rows"



                        echo "  │  │  └─ 追踪完成"

                        # === Streaming Report (Trace Item) ===
                        {
                            echo "#### $name ($mode)"
                            # 如果是动态 CDN 目标，显示解析到的域名
                            if [[ "$name" == *"Dynamic"* ]]; then
                                echo "命中 CDN 节点: \`$target\`"
                                echo ""
                            fi
                            echo -e "$table"
                            echo ""
                        } >> "$REPORT_FILE"
                    else
                        echo "  │  │  └─ 失败: 解析结果为空"
                        # TRACE_RESULTS+=("### $name ($mode)|> Trace Failed (Parse Error)")
                    fi
                fi
            fi

        done
    done

    info "  └─ 路由追踪完成"
}

# =========================
# 去程路由追踪 (Forward Route Trace)
# 使用 nexttrace --from 参数从全球各地追踪到本服务器
# =========================
run_forward_trace_test() {
    log "开始去程路由追踪..."

    if [ "$NEXTTRACE_BIN" == "false" ] || [ -z "$NEXTTRACE_BIN" ]; then
        warn "  └─ NextTrace 二进制未找到或下载失败，跳过";
        return;
    fi

    if [ ! -x "$NEXTTRACE_BIN" ] && ! command -v "$NEXTTRACE_BIN" >/dev/null 2>&1; then
        warn "  └─ NextTrace ($NEXTTRACE_BIN) 不可执行，跳过";
        return;
    fi

    # 获取本机公网 IPv4 地址
    local my_ipv4=""
    if [ "$HAS_V4" = "true" ]; then
        my_ipv4=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null || \
                  curl -s4 --max-time 5 https://ipv4.icanhazip.com 2>/dev/null || \
                  curl -s4 --max-time 5 https://ifconfig.me 2>/dev/null)
    fi

    if [ -z "$my_ipv4" ]; then
        warn "  └─ 无法获取本机公网 IPv4 地址，跳过去程路由追踪"
        return
    fi

    info "  ├─ 目标 IP: $my_ipv4"

    # 去程追踪源列表: 国家+ASN 组合
    # 格式: "显示名称|--from参数"
    # 下载去程追踪源列表
    local sources_url="https://raw.githubusercontent.com/Lowendaff/linux_bench/main/utils/forward_sources.txt"
    local sources_file="$TMP_DIR/forward_sources.txt"

    echo "  ├─ 下载追踪源列表..."
    if ! retry_download "$sources_file" "$sources_url" "Forward Sources" "--connect-timeout 5 --max-time 10"; then
        warn "  │  └─ 下载失败，使用内置源"
        # Fallback: 使用基础的三大运营商
        cat > "$sources_file" << 'FALLBACK_EOF'
中国电信 163|CN+AS4134
中国联通 169|CN+AS4837
中国移动 CMNET|CN+AS9808
FALLBACK_EOF
    fi

    # 读取源列表到数组
    local forward_sources=()
    while IFS= read -r line; do
        # 跳过空行和注释行（但保留 #GROUP: 标记）
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^#[^G] ]] && continue
        [[ "$line" =~ ^#$ ]] && continue
        forward_sources+=("$line")
    done < "$sources_file"

    # 计算实际源数量（排除 #GROUP: 行）
    local total=0
    for src in "${forward_sources[@]}"; do
        [[ "$src" != "#GROUP:"* ]] && total=$((total+1))
    done
    local idx=0

    # 写入报告头
    {
        echo "## 去程路由追踪"
        echo ""
        local masked_ip=$(echo "$my_ipv4" | sed 's/\([0-9]*\.[0-9]*\)\.[0-9]*\.[0-9]*/\1.xx.xx/')
        echo "从全球各地追踪到本服务器 \`$masked_ip\`"
        echo ""
    } >> "$REPORT_FILE"

    for source in "${forward_sources[@]}"; do
        # 处理分组标记
        if [[ "$source" == "#GROUP:"* ]]; then
            local group_name="${source#\#GROUP:}"
            echo "  ├── $group_name"
            {
                echo ""
                echo "### $group_name"
                echo ""
            } >> "$REPORT_FILE"
            continue
        fi

        idx=$((idx+1))
        local name="${source%%|*}"
        local from_param="${source##*|}"

        echo "  │  ├─ [$idx/$total] 从 $name 追踪..."

        # 运行 nexttrace --from
        local raw_output=""
        local err_file="$TMP_DIR/nt_fwd_err_$idx.log"
        raw_output=$("$NEXTTRACE_BIN" --json --tcp --psize 1400 --from "$from_param" "$my_ipv4" 2>"$err_file")
        local err_out=$(cat "$err_file" 2>/dev/null)
        rm -f "$err_file"

        # 提取 JSON 部分
        local json=$(echo "$raw_output" | sed 's/^[^{]*//')

        if [ -z "$json" ] || ! echo "$json" | jq -e . >/dev/null 2>&1; then
            echo "  │  └─ 失败: 无效输出"
            if [ -n "$err_out" ]; then
                local clean_err=$(echo "$err_out" | sed 's/\x1b\[[0-9;]*m//g' | head -n 1)
                echo "  │     (错误): ${clean_err:0:80}"
            fi
            continue
        fi

        # 解析 JSON 并生成表格
        local table="| 跳数 | IP | ASN | 位置 | 运营商 | 延迟 |\n"
        table+="|---:|:---|:---|:---|:---|---:|\n"

        # 根据 NORMALIZE_OUTPUT 构建不同的 jq 查询
        local jq_loc_filter
        if [ "$NORMALIZE_OUTPUT" = "true" ]; then
            jq_loc_filter='map(select(. and . != "") | if (. | length) > 2 then gsub("市$|省$|州$"; "") else . end)'
        else
            jq_loc_filter='map(select(. and . != ""))'
        fi

        local rows=$(echo "$json" | jq -r '
            .Hops | to_entries[] |
            (.key + 1) as $hopnum |
            .value as $probes |
            ([$probes[] | select(.Success == true)][0] // $probes[0] // {}) as $p |
            (if $p.Address then ($p.Address.IP // "*") else "*" end) as $ip |
            (if $p.Geo and ($p.Geo.asnumber // "") != "" then "AS" + $p.Geo.asnumber else "-" end) as $asn |
            (if $p.Geo then
                ([$p.Geo.country, $p.Geo.prov, $p.Geo.city] | '"$jq_loc_filter"' | reduce .[] as $x ([]; if . | index($x) then . else . + [$x] end) | join(" "))
            else "" end) as $loc_raw |
            (if $loc_raw == "" then "-" else $loc_raw end) as $loc |
            (if $p.Geo then
                (if ($p.Geo.isp // "") != "" then $p.Geo.isp
                 elif ($p.Geo.owner // "") != "" then $p.Geo.owner
                 else "-" end)
            else "-" end) as $isp |
            (if $p.RTT and $p.RTT > 0 then
                (($p.RTT / 1000000 * 100 | floor) / 100 | tostring)
            else "-" end) as $rtt |
            [$hopnum, $ip, $asn, $loc, $isp, $rtt] | @tsv
        ' 2>/dev/null)

        if [ -n "$rows" ]; then
            while IFS=$'\t' read -r ttl ip asn loc isp rtt; do
                [ -z "$ip" ] && continue
                [ "$ip" = "*" ] && ip="-"

                # 运营商名称规范化（仅在标准化输出模式下）
                if [ "$NORMALIZE_OUTPUT" = "true" ]; then
                    isp=$(normalize_isp_name "$isp")
                fi

                # RTT格式
                if [ "$rtt" != "-" ] && [ -n "$rtt" ]; then
                    rtt_display="$rtt ms"
                else
                    rtt_display="-"
                fi
                table+="| $ttl | $ip | $asn | $loc | $isp | $rtt_display |\n"
            done <<< "$rows"

            echo "  │  └─ 追踪完成"

            # 写入报告
            {
                echo "#### $name"
                echo ""
                echo "源: \`--from $from_param\`"
                echo ""
                echo -e "$table"
                echo ""
            } >> "$REPORT_FILE"
        else
            echo "  │  └─ 失败: 解析结果为空"
        fi

        # 避免请求过快
        sleep 0.5
    done

    info "  └─ 去程路由追踪完成"
}

init_report() {
    > "$REPORT_FILE"
    echo "# Bench Report" >> "$REPORT_FILE"
    echo "Generated at $(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S') China Standard Time" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
}

main() {
    parse_args "$@"
    preflight_checks
    clear

    # ASCII 艺术字
    echo -e "${GREEN}"
    cat <<'EOF'
  _     _                    ____                  _
 | |   (_)_ __  _   ___  __ | __ )  ___ _ __   ___| |__
 | |   | | '_ \| | | \ \/ / |  _ \ / _ | '_ \ / __| '_ \
 | |___| | | | | |_| |>  <  | |_) |  __| | | | (__| | | |
 |_____|_|_| |_|\__,_/_/\_\ |____/ \___|_| |_|\___|_| |_|

EOF
    echo -e "${NC}"

    # 功能与开关说明
    echo -e "==> 欢迎使用 Lowendaff LinuxBench，这是一个综合的测试工具"
    echo -e ""
    print_feature_list
    echo -e ""
    echo -e "[*] 访问我们的网站 https://lowendaff.com"
    echo -e "[*] 关注我们的 Telegram 频道 https://t.me/lowendaff_blog"
    echo -e ""
    sleep 1

    # Initialize Report
    init_report
    log "输出文件: $REPORT_FILE"

    # 已启用功能概览
    local _enabled=""
    [ "$RUN_SYSINFO" = "true" ]       && _enabled+=" 系统信息"
    [ "$RUN_NET_INFO" = "true" ]      && _enabled+=" 网络信息"
    [ "$RUN_BGP" = "true" ]           && _enabled+=" BGP"
    [ "$RUN_IP_QUALITY" = "true" ]    && _enabled+=" IP质量"
    [ "$RUN_STREAM" = "true" ]        && _enabled+=" 服务解锁"
    [ "$RUN_CPU" = "true" ]           && _enabled+=" CPU"
    [ "$RUN_GB" = "true" ]            && _enabled+=" Geekbench"
    [ "$RUN_DISK" = "true" ]          && _enabled+=" 磁盘"
    [ "$RUN_IPERF" = "true" ]         && _enabled+=" iperf3"
    [ "$RUN_CF" = "true" ]            && _enabled+=" Cloudflare测速"
    [ "$RUN_APPLE" = "true" ]         && _enabled+=" Apple测速"
    [ "$RUN_TRACE" = "true" ]         && _enabled+=" 回程追踪"
    [ "$RUN_FORWARD_TRACE" = "true" ] && _enabled+=" 去程追踪"
    log "${CYAN}已启用:${_enabled:- (无)}${NC}"
    if [ "$RUN_NET_INFO" = "false" ]; then
        warn "已跳过网络信息(--skip-netinfo):BGP / IP质量 / 服务解锁 / iperf / 回程 / 去程 已一并跳过"
    fi

    if [ "$SKIP_V6" = "true" ]; then
        log "${CYAN}限制: 仅运行 IPv4 测试 (-4)${NC}"
    elif [ "$SKIP_V4" = "true" ]; then
        log "${CYAN}限制: 仅运行 IPv6 测试 (-6)${NC}"
    fi

    if [ "$FIX_DNS" = "true" ]; then
        mkdir -p "$TMP_DIR"
        if apply_dns_override; then
            log "${YELLOW}应用: 强制临时覆盖系统 DNS (--fix-dns)${NC}"
        fi
    fi

    ensure_dependencies

    # 各功能按开关运行(默认全开,--skip-xxx 关闭单项;netinfo 级联已在 parse_args 处理)
    if [ "$RUN_SYSINFO" = "true" ]; then collect_system_info; fi
    if [ "$RUN_NET_INFO" = "true" ]; then collect_network_info; fi
    if [ "$RUN_BGP" = "true" ]; then collect_bgp_view; fi
    if [ "$RUN_IP_QUALITY" = "true" ]; then collect_ip_quality; fi
    if [ "$RUN_STREAM" = "true" ]; then run_stream_test; fi
    if [ "$RUN_CPU" = "true" ]; then run_cpu_test; fi
    if [ "$RUN_GB" = "true" ]; then run_gb6_test; fi
    if [ "$RUN_DISK" = "true" ]; then run_disk_test; fi
    if [ "$RUN_IPERF" = "true" ]; then run_iperf_test; fi
    if [ "$RUN_CF" = "true" ]; then run_cloudflare_speedtest; fi
    if [ "$RUN_APPLE" = "true" ]; then run_apple_speedtest; fi
    if [ "$RUN_TRACE" = "true" ]; then run_trace_test; fi
    if [ "$RUN_FORWARD_TRACE" = "true" ]; then run_forward_trace_test; fi

    info "测试完成! 报告已保存至 $REPORT_FILE"
}

# 仅在脚本被直接执行时运行 main;被 source 时只定义函数(便于测试)。
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
