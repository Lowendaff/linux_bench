import os
import random
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "utils"))
from fetch_forward_sources import build_sources


def probe(country, asn, city="", network=""):
    return {"location": {"country": country, "asn": asn, "city": city, "network": network}}


FIXTURE = [
    probe("CN", 4134, "Shenzhen", "Chinanet Backbone"),
    probe("CN", 4134, "Guangzhou", "Chinanet"),       # 同 ASN 第二探针 -> 去重
    probe("CN", 9808, "Beijing", "China Mobile"),
    probe("CN", 45090, "Shenzhen", "Tencent"),
    probe("CN", 136188, "Ningbo", "NINGBO ZHEJIANG"),  # 未知 -> 中国其他 自动命名
    probe("US", 174, "New York", "Cogent"),            # 非 CN -> 不进动态分组
    probe("CN", None, "X", "weird"),                   # 无效 asn -> 跳过
]


class TestBuildSources(unittest.TestCase):
    def setUp(self):
        self.text = build_sources(FIXTURE)

    def test_known_asn_named_and_grouped(self):
        self.assertIn("中国电信 163|CN+AS4134", self.text)
        self.assertIn("中国移动 CMNET|CN+AS9808", self.text)
        self.assertIn("腾讯云|CN+AS45090", self.text)

    def test_unknown_asn_auto_named_in_other(self):
        self.assertIn("Ningbo (AS136188)|CN+AS136188", self.text)
        self.assertIn("#GROUP:中国其他", self.text)

    def test_dedup_by_asn(self):
        self.assertEqual(self.text.count("CN+AS4134"), 1)

    def test_only_valid_cn_dynamic_entries(self):
        # 去重且有效的 CN ASN: 4134, 9808, 45090, 136188 = 4
        self.assertEqual(self.text.count("CN+AS"), 4)

    def test_known_asn_without_probe_absent(self):
        # AS4809(CN2) 在 ASN_INFO 但夹具无探针 -> 不出现
        self.assertNotIn("CN+AS4809", self.text)

    def test_group_order(self):
        i_tel = self.text.index("#GROUP:中国电信")
        i_mob = self.text.index("#GROUP:中国移动")
        i_cloud = self.text.index("#GROUP:中国云厂商")
        i_other = self.text.index("#GROUP:中国其他")
        self.assertTrue(i_tel < i_mob < i_cloud < i_other)

    def test_city_sanitized_in_auto_name(self):
        malicious_probe = probe("CN", 999999, "Bad|City\nEvil", "x")
        t = build_sources([malicious_probe])
        self.assertNotIn("Bad|City", t)
        self.assertIn("CN+AS999999", t)
        # the auto-named line must not embed a raw | or newline in the display name
        for line in t.splitlines():
            if "CN+AS999999" in line:
                name_part = line.split("|")[0]
                self.assertNotIn("|", name_part)
                self.assertNotIn("\n", name_part)
                self.assertNotIn("\r", name_part)

    def test_static_tail_present(self):
        self.assertIn("#GROUP:亚太地区", self.text)
        self.assertIn("香港 PCCW|HK+AS3491", self.text)
        self.assertIn("美国 Cogent|US+AS174", self.text)

    def test_empty_cn_has_no_dynamic_but_keeps_tail(self):
        t = build_sources([probe("US", 174, "NYC", "Cogent")])
        self.assertNotIn("CN+AS", t)         # main 据此 exit 1
        self.assertIn("#GROUP:亚太地区", t)   # 静态尾块仍在

    def test_deterministic_regardless_of_input_order(self):
        shuffled = FIXTURE[:]
        random.shuffle(shuffled)
        self.assertEqual(build_sources(shuffled), self.text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
