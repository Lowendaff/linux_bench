#!/usr/bin/env bash
# 运行 tests/ 下所有 test_*.sh,任一失败则整体失败。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
rc=0
for t in "$HERE"/test_*.sh; do
    echo "=== $(basename "$t") ==="
    bash "$t" || rc=1
    echo ""
done
exit "$rc"
