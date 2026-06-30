#!/usr/bin/env bash
# 验证 gb6_scores_blocked:两个分数都空但有结果 URL(GB6 免费版上传成功、
# 但本机抓取结果页被 Cloudflare 拦截)时为真;其余为假。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/assert.sh"
LB="$HERE/../linux_bench.sh"
source "$LB" 2>/dev/null

U="https://browser.geekbench.com/v6/cpu/123"
assert_success gb6_scores_blocked ""     ""     "$U"   # 都空 + 有 URL -> 抓取被挡
assert_fail    gb6_scores_blocked "1500" "8000" "$U"   # 有分数 -> 否
assert_fail    gb6_scores_blocked "1500" ""     "$U"   # 仅单核有 -> 否
assert_fail    gb6_scores_blocked ""     "8000" "$U"   # 仅多核有 -> 否
assert_fail    gb6_scores_blocked ""     ""     ""      # 无 URL(没上传/真失败) -> 否

finish
