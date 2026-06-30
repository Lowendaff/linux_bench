#!/usr/bin/env python3
"""从 Globalping 探针数据生成去程追踪源列表 utils/forward_sources.txt。

中国大陆分组按 ASN 自动生成(只含当前有探针的 ASN);非中国分组为静态维护。
"""
import json
import logging
import os
import sys
import urllib.request

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)

OUTPUT_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "forward_sources.txt")
PROBES_URL = "https://api.globalping.io/v1/probes"

# 已知中国大陆 ASN -> (分组, 显示名)
ASN_INFO = {
    4134:   ("中国电信", "中国电信 163"),
    4809:   ("中国电信", "中国电信 CN2"),
    4847:   ("中国电信", "中国电信 AS4847"),
    151185: ("中国电信", "中国电信 (武汉)"),
    4837:   ("中国联通", "中国联通 169"),
    9929:   ("中国联通", "中国联通 A网 (9929)"),
    4808:   ("中国联通", "中国联通 (北京)"),
    17621:  ("中国联通", "中国联通 (上海)"),
    9808:   ("中国移动", "中国移动 CMNET"),
    58807:  ("中国移动", "中国移动 CMIN2"),
    56048:  ("中国移动", "中国移动 (北京)"),
    24400:  ("中国移动", "中国移动 (上海)"),
    24445:  ("中国移动", "中国移动 (河南)"),
    56046:  ("中国移动", "中国移动 (扬州)"),
    56047:  ("中国移动", "中国移动 (长沙)"),
    45090:  ("中国云厂商", "腾讯云"),
    37963:  ("中国云厂商", "阿里云"),
    55990:  ("中国云厂商", "华为云"),
    17962:  ("中国其他", "深圳天威 (Topway)"),
}
GROUP_ORDER = ["中国电信", "中国联通", "中国移动", "中国云厂商", "中国其他"]
OTHER_GROUP = "中国其他"

HEADER = (
    "# 去程路由追踪源列表 (Forward Trace Sources)\n"
    "# 格式: 显示名称|--from参数\n"
    "# 每行一个源，#开头的行为注释或分组标记\n"
    "# #GROUP:分组名 用于在报告中分组显示\n"
    "# 中国大陆分组由 utils/fetch_forward_sources.py 从 Globalping 探针自动生成；非中国分组为静态维护。\n"
)

STATIC_TAIL = """#GROUP:亚太地区
香港 PCCW|HK+AS3491
香港 HGC|HK+AS9304
日本 NTT|JP+AS2914
日本 KDDI|JP+AS2516
新加坡 Singtel|SG+AS7473
韩国 KT|KR+AS4766

#GROUP:欧洲
德国 DTAG|DE+AS3320
英国 BT|GB+AS5400
法国 Orange|FR+AS5511

#GROUP:北美
美国 Cogent|US+AS174
美国 Lumen|US+AS3356
美国 GTT|US+AS3257
"""


def build_sources(probes):
    """纯函数:输入 Globalping 探针列表,返回 forward_sources.txt 完整文本。"""
    cities_by_asn = {}
    for p in probes:
        loc = p.get("location") or {}
        if loc.get("country") != "CN":
            continue
        asn = loc.get("asn")
        if not isinstance(asn, int):
            continue
        cities_by_asn.setdefault(asn, []).append(loc.get("city") or "")

    grouped = {g: [] for g in GROUP_ORDER}
    for asn in sorted(cities_by_asn):
        if asn in ASN_INFO:
            group, name = ASN_INFO[asn]
        else:
            cities = sorted(c for c in set(cities_by_asn[asn]) if c)
            city = cities[0] if cities else "?"
            group, name = OTHER_GROUP, "{} (AS{})".format(city, asn)
        grouped[group].append((asn, name))

    parts = [HEADER]
    for group in GROUP_ORDER:
        if not grouped[group]:
            continue
        parts.append("\n#GROUP:{}\n".format(group))
        for asn, name in grouped[group]:
            parts.append("{}|CN+AS{}\n".format(name, asn))
    parts.append("\n" + STATIC_TAIL)
    return "".join(parts)
