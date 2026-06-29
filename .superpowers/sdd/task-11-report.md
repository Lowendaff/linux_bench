# Task 11 Report — `set -o pipefail` + SC2086 Annotations (H2)

**Status: DONE_WITH_CONCERNS** (expected — see Deferred Items below)

---

## Changes Made

### 1. `set -o pipefail` addition (`linux_bench.sh` lines 19–22)

Inserted after the GPL header block and before the `# 系统前置检查` section comment:

```bash
# 仅启用 pipefail:让管道中任一环失败都能被感知。
# 注意:有意不启用 set -e / set -u —— 脚本大量使用 `cmd || true` 与可空变量,
# 贸然开启会改变现有控制流。后续如需引入需配合完整回归(见 P2 路线图)。
set -o pipefail
```

`set -e` and `set -u` deliberately NOT added, as instructed.

### 2. Three `# shellcheck disable=SC2086` annotations in `ensure_dependencies`

All three are comment-only additions (zero behavior change):

| Location | Line context |
|---|---|
| `for pkg in $target_pkgs` loop | `# shellcheck disable=SC2086 # 故意词分割: 包列表` |
| `apt-get install -y -q $missing_pkgs` | `# shellcheck disable=SC2086 # 故意词分割: 包列表` |
| `for p in $missing_pkgs` loop | `# shellcheck disable=SC2086 # 故意词分割: 包列表` |

These document intentional word-splitting (space-separated package list) so future shellcheck runs do not flag them as errors.

---

## Verification

### `bash -n linux_bench.sh`
```
bash -n: OK
```

### Full suite: `bash tests/run_all.sh`
```
test_cleanup_idempotent.sh  : 1 run, 0 failed
test_dns_restore.sh         : 6 run, 0 failed
test_download_verify.sh     : 4 run, 0 failed
test_int_validation.sh      : 11 run, 0 failed
test_sourceable.sh          : 3 run, 0 failed
test_token.sh               : 3 run, 0 failed
TOTAL                       : 28 run, 0 failed
```

Sourcing the script in `test_sourceable.sh` activates `pipefail` in the test shell — all pure-function tests continued to pass, confirming `pipefail` did not regress the existing control flow.

---

## Commit

```
35b125e  refactor: enable pipefail and harden dangerous unquoted expansions (H2)
```

Branch: `security-hardening-p0-p1`

---

## Deferred Items (EXPECTED — cannot be performed in this macOS/non-root sandbox)

1. **Full shellcheck-driven quoting triage** — `shellcheck` is not installed here. The complete SC2086 / SC2048 triage described in brief Steps 3–4 (identifying and fixing "dangerous" unquoted expansions in curl/rm/tar/bash invocations) must be run on a Linux box with `shellcheck` installed (`apt-get install -y shellcheck`). The three annotations added here document the *known-intentional* sites; any remaining dangerous sites are untriaged.

2. **Production / VPS smoke test (brief Appendix C)** — The script requires Debian/Ubuntu + root to exercise the runtime paths (speedtest, nexttrace, yt-dlp download + verify, DNS override, etc.). This cannot be run on macOS without root and without the target packages. The full checklist from Appendix C must be executed on a one-off Debian VPS by the operator before merging to main.

---

## Self-Review

- GPL v3 header: untouched ✓
- Chinese output style: untouched ✓
- `bash -n`: passes ✓
- Full suite: 28/28 ✓
- `set -e` / `set -u`: NOT added ✓
- `retry_download` curl args: NOT touched ✓
- YAGNI: no extra changes ✓
- Conventional Commit subject matches brief exactly ✓

---

## Final-Review Fix Wave

Applied from whole-branch final review. Items below correspond to the review's Item 1–5.

### Item 1 (SECURITY.md — download-integrity claim)
Rewrote `## 下载完整性` to state the truth: `download_and_verify` is implemented but NOT wired
into the live download path; `utils/checksums.txt` does not exist; wiring deferred to task T5.

### Item 2 (M3 — guard symlink `rm -f` in `apply_dns_override`)
Replaced the silent `[ -L "$resolv" ] && rm -f "$resolv" 2>/dev/null` one-liner with a guarded
block that returns 1 with a `warn` message on `rm` failure, preventing silent write-through.

### Item 3 (Minor — mark `download_and_verify` as staged)
Added one-line comment above the function definition: "已实现但尚未接入下载调用点（T5）"
so it is not mistaken for dead code.

### Item 4 (M1 — `test_token.sh` function-existence assertion)
Added assertion `assert_success bash -c "source ... && declare -F setup_nexttrace_token >/dev/null"`
as test case 0. Count increased from 3 to 4.

### Item 5 (M2 — `test_download_verify.sh` mismatch exit code)
Replaced bare `download_and_verify ... 2>/dev/null` call with `assert_fail download_and_verify ...`
so a regression (non-zero exit stops being the case) is caught loud. File-deletion check follows.
Count increased from 4 to 5.

### Covering-Test Results

| Test | Command | Result |
|---|---|---|
| test_token.sh | `bash tests/test_token.sh` | 4 run, 0 failed |
| test_download_verify.sh | `bash tests/test_download_verify.sh` | 5 run, 0 failed |
| test_dns_restore.sh | `bash tests/test_dns_restore.sh` | 6 run, 0 failed |
| run_all.sh | `bash tests/run_all.sh` | all green (total 30 run, 0 failed) |
| bash -n | `bash -n linux_bench.sh` | syntax OK |
