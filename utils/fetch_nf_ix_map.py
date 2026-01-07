#!/usr/bin/env python3
"""
Fetch Netflix IX (Internet Exchange) IP mappings from PeeringDB.
This script scrapes Netflix's PeeringDB page and extracts IX names with their IP addresses.
"""

import html
import logging
import re
import sys
import urllib.request

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)

import os
OUTPUT_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "nf_ix_map.txt")


def fetch_and_parse():
    logging.info(f"开始任务，正在访问: {URL}")

    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Safari/537.36"
    }

    req = urllib.request.Request(URL, headers=headers)

    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            html_content = response.read().decode("utf-8")
            logging.info(f"HTTP 请求成功，状态码: {response.status}")
    except Exception as e:
        logging.error(f"HTTP 请求失败: {e}")
        sys.exit(1)

    logging.info("正在解析 HTML 数据...")

    chunks = re.split(r'<div class=["\']row item', html_content)

    results = []

    for chunk in chunks[1:]:
        ix_name_match = re.search(
            r'class=["\']exchange.*?<a[^>]*>(.*?)</a>', chunk, re.DOTALL | re.IGNORECASE
        )

        if not ix_name_match:
            continue

        raw_name = ix_name_match.group(1).strip()
        ix_name = html.unescape(raw_name)

        ip4_match = re.search(
            r'class=["\']ip4["\'][^>]*>\s*(.*?)\s*</div>',
            chunk,
            re.DOTALL | re.IGNORECASE,
        )
        if ip4_match:
            ip4 = ip4_match.group(1).strip()
            if ip4:
                results.append(f"{ip4} {ix_name}")

        ip6_match = re.search(
            r'class=["\']ip6["\'][^>]*>\s*(.*?)\s*</div>',
            chunk,
            re.DOTALL | re.IGNORECASE,
        )
        if ip6_match:
            ip6 = ip6_match.group(1).strip()
            if ip6:
                results.append(f"{ip6} {ix_name}")

    if results:
        try:
            with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
                for line in results:
                    f.write(line + "\n")

            logging.info(f"解析完成，共提取到 {len(results)} 条记录")
            logging.info(f"结果已保存至: {OUTPUT_FILE}")

        except IOError as e:
            logging.error(f"写入文件失败: {e}")
            sys.exit(1)
    else:
        logging.warning("未提取到任何数据，请检查 HTML 结构或网络响应内容")
        sys.exit(1)


if __name__ == "__main__":
    fetch_and_parse()
