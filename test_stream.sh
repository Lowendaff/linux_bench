#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# 流媒体检测测试脚本 - 用于调试和分析原始输出

set -e

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 临时目录
TMP_DIR="./tmp_stream_test_$(date +%s)"
mkdir -p "$TMP_DIR"

# 清理函数
cleanup() {
    rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

echo "=========================================="
echo "流媒体检测测试脚本"
echo "=========================================="
echo ""

# 区域选择 (默认: 0 = 全球 + 日本)
region_id="${1:-0}"
region_name="跨国平台+日本平台"

echo "测试区域: $region_name (ID: $region_id)"
echo ""

# 下载测试脚本
stream_script_url="https://github.com/1-stream/RegionRestrictionCheck/raw/main/check.sh"
stream_script_file="$TMP_DIR/check_stream.sh"

echo -n "正在下载测试脚本..."
if curl -f -L -s -o "$stream_script_file" "$stream_script_url" 2>/dev/null; then
    echo -e " ${GREEN}完成${NC}"
else
    echo -e " ${RED}失败${NC}"
    exit 1
fi

# 将 python json.tool 替换为 jq（加上错误重定向）
sed -i -E 's/python3?  *-m json\.tool( 2>\/dev\/null)?/jq . 2>\/dev\/null/g' "$stream_script_file"
chmod +x "$stream_script_file"

# ========== 第一步：查看原始输出 ==========
echo ""
echo "=========================================="
echo "第一步：原始输出 (IPv4)"
echo "=========================================="
echo ""

raw_output_file="$TMP_DIR/raw_output.txt"

# 执行测试并保存原始输出
if command -v script >/dev/null 2>&1; then
    TERM=xterm-256color script -q -c "echo '$region_id' | bash '$stream_script_file' -M 4" "$raw_output_file" >/dev/null 2>&1
else
    echo "$region_id" | bash "$stream_script_file" -M 4 > "$raw_output_file" 2>&1
fi

echo "原始输出已保存到: $raw_output_file"
echo ""
echo "--- 原始输出内容 (前100行) ---"
head -n 100 "$raw_output_file"
echo ""
echo "--- 原始输出结束 ---"

# ========== 第二步：清理后的输出 ==========
echo ""
echo "=========================================="
echo "第二步：清理 ANSI 颜色后的输出"
echo "=========================================="
echo ""

cleaned_output=$(cat "$raw_output_file" | \
    sed 's/\x1b\[[0-9;]*m//g' | \
    sed 's/\x1b\[H\x1b\[2J//g' | \
    sed 's/\x1b\[?25[hl]//g' | \
    tr -d '\r')

echo "$cleaned_output" > "$TMP_DIR/cleaned_output.txt"
echo "清理后输出已保存到: $TMP_DIR/cleaned_output.txt"
echo ""
echo "--- 清理后输出内容 (前100行) ---"
head -n 100 "$TMP_DIR/cleaned_output.txt"
echo ""
echo "--- 清理后输出结束 ---"

# ========== 第三步：解析为表格格式 ==========
echo ""
echo "=========================================="
echo "第三步：解析为表格格式"
echo "=========================================="
echo ""

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
                local service=$(echo "$line" | sed 's/^\s*//' | cut -d':' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                local status=$(echo "$line" | sed 's/^\s*//' | cut -d':' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                
                # 直接使用原始状态，不做转换
                results="${results}${service}|${status}\n"
            fi
        fi
    done <<< "$cleaned"
    
    echo -e "$results"
}

# 解析并输出
echo "| 服务 | 状态 |"
echo "| :--- | :--- |"

parse_stream_to_table "$(cat "$raw_output_file")" "IPv4" | while IFS='|' read -r service status; do
    if [ -n "$service" ]; then
        # 跳过分类标题
        if [[ "$service" == CATEGORY:* ]]; then
            cat_name="${service#CATEGORY:}"
            echo ""
            echo "=== $cat_name ==="
            echo "| 服务 | 状态 |"
            echo "| :--- | :--- |"
        elif [[ "$service" == SUBCATEGORY:* ]]; then
            subcat_name="${service#SUBCATEGORY:}"
            echo "--- $subcat_name ---"
        else
            # 跳过 Microsoft Copilot
            [[ "$service" == *"Microsoft Copilot"* ]] && continue
            echo "| $service | $status |"
        fi
    fi
done

echo ""
echo "=========================================="
echo "测试完成"
echo "=========================================="
echo ""
echo "原始输出文件: $raw_output_file"
echo "清理后文件: $TMP_DIR/cleaned_output.txt"
echo ""
echo "你可以用以下命令查看完整输出:"
echo "  cat $raw_output_file"
echo "  cat $TMP_DIR/cleaned_output.txt"
