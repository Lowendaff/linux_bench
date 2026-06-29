# Linux Bench 安全与健壮性加固 (P0+P1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 `linux_bench.sh` 的 P0 安全问题(硬编码凭据、下载零校验、DNS 覆盖不恢复)与 P1 健壮性问题(临时目录、整数校验、上游脚本锁定、若干小修与 pipefail/引号加固),不触及 P2 大重构。

**Architecture:** 在不重写单体脚本的前提下,引入两个支撑能力 ——(1)让脚本**可被 `source`** 而不执行,从而能对纯函数做单元测试;(2)一个**带 sha256 校验的下载函数** `download_and_verify`,所有外部二进制/脚本下载统一经它。其余修复都是把易错的内联逻辑抽成**小而可测的函数**(DNS 覆盖/恢复、整数校验、token 设置、cleanup 幂等),再在调用点替换。

**Tech Stack:** Bash 4+(目标平台 Debian/Ubuntu)、`curl`、`jq`、`sha256sum`/`shasum`、`shellcheck`(开发期 lint)、纯 Bash 自研测试运行器(无第三方依赖,本机/CI/Linux 均可跑)。

## Global Constraints

- 目标平台仅 **Debian / Ubuntu**,脚本以 **root** 运行;改动不得削弱现有 root 前置检查。
- **不得引入运行期新依赖**:`sha256sum` 在目标平台默认存在;测试运行器只用 Bash + coreutils。
- 保持 **GNU GPL v3** 头部与中文输出风格不变。
- 提交信息沿用仓库的 **Conventional Commits** 风格(`feat: / fix: / refactor: / test: / docs: / chore:`)。
- 行号会随改动漂移,**以函数名定位为准**,行号仅作参考。
- 范围**仅 P0+P1**;`normalize_isp_name` 查表化、模块化拆分、去重等 P2 项**不在本计划内**。
- 每个改动后 `bash -n linux_bench.sh` 必须通过(语法门禁)。

## 测试策略(务必先读)

本项目无测试基线,且多数修复是 root 副作用,无法安全自动化。本计划据此分三类门禁:

1. **单元测试(真测)** —— 针对抽出的纯函数:`download_and_verify`、`is_uint`/`is_num`/`format_fraud_score`、`apply_dns_override`/`restore_dns_override`、`setup_nexttrace_token`、`cleanup` 幂等。测试 `source ./linux_bench.sh` 后直接调函数,断言行为。用 `tests/assert.sh`(自研)。
2. **静态门禁(每个任务必跑)** —— `bash -n linux_bench.sh`(语法)+ 针对改动函数的 `shellcheck`(若已安装)。
3. **手动冒烟(集成路径)** —— 触及真实下载/`/etc`/swap/apt 的路径,在一台**一次性 VPS**上按附录 B 的步骤手测,记录预期输出。计划中明确标注"无法单元测试,走手动冒烟"。

## File Structure

| 文件 | 责任 | 操作 |
| :--- | :--- | :--- |
| `linux_bench.sh` | 主脚本 | 多任务修改 |
| `linux_bench.old.sh` | 陈旧副本 | **删除**(T2) |
| `tests/assert.sh` | 极简断言库 | 新建(T1) |
| `tests/run_all.sh` | 汇总运行所有测试 | 新建(T1) |
| `tests/test_sourceable.sh` | 验证可 source、函数已定义 | 新建(T1) |
| `tests/test_token.sh` | `setup_nexttrace_token`(T3) | 新建 |
| `tests/test_download_verify.sh` | `download_and_verify`(T4) | 新建 |
| `tests/fixtures/sample.bin` | 下载校验测试夹具 | 新建(T4) |
| `tests/test_dns_restore.sh` | DNS 覆盖/恢复(T6) | 新建 |
| `tests/test_int_validation.sh` | 整数/数字校验(T8) | 新建 |
| `tests/test_cleanup_idempotent.sh` | cleanup 幂等(T10) | 新建 |
| `utils/checksums.txt` | 各工具的期望 sha256(maintainer 维护) | 新建(T5) |
| `docs/code-review-2026-06-29.md` | 源审查报告 | 只读引用 |
| `SECURITY.md` | 记录 token 轮换/校验和策略 | 新建(T3) |

---

## Task 1: 测试支撑 —— 让脚本可 source + 断言库

**为什么先做:** 当前脚本顶部有 OS/root 前置检查(非 Debian/Ubuntu 直接 `exit`),底部直接 `main`。这使得 `source ./linux_bench.sh` 在开发机(如 macOS)上会立刻退出,无法对任何函数做单元测试。本任务把前置检查移入函数、把 `main` 调用加 source 守卫,从而解锁后续所有单元测试。这是最小化改动,**不改变被执行时的行为**。

**Files:**
- Modify: `linux_bench.sh`(顶部前置检查块 ~21-43;底部 `main` 调用 ~3281;`main()` 开头 ~3134)
- Create: `tests/assert.sh`
- Create: `tests/run_all.sh`
- Create: `tests/test_sourceable.sh`

**Interfaces:**
- Produces: `preflight_checks()`(无参,执行原 OS/root 校验,失败 `exit 1`);脚本被 `source` 时**只定义函数、不执行 main / 不做前置检查**;被直接执行时行为与现状一致。
- Produces(测试库): `assert_eq <got> <want> <msg>`、`assert_success <cmd...>`、`assert_fail <cmd...>`、`assert_contains <haystack> <needle> <msg>`、`finish`(有失败则返回非 0)。

- [ ] **Step 1: 写断言库 `tests/assert.sh`**

```bash
#!/usr/bin/env bash
# 极简纯 Bash 断言库,无第三方依赖。
TESTS_RUN=0
TESTS_FAILED=0

assert_eq() { # got want msg
    TESTS_RUN=$((TESTS_RUN+1))
    if [ "$1" = "$2" ]; then
        echo "ok: $3"
    else
        echo "FAIL: $3 (expected '$2', got '$1')"
        TESTS_FAILED=$((TESTS_FAILED+1))
    fi
}

assert_contains() { # haystack needle msg
    TESTS_RUN=$((TESTS_RUN+1))
    if [[ "$1" == *"$2"* ]]; then
        echo "ok: $3"
    else
        echo "FAIL: $3 (string '$1' does not contain '$2')"
        TESTS_FAILED=$((TESTS_FAILED+1))
    fi
}

assert_success() { # cmd...
    TESTS_RUN=$((TESTS_RUN+1))
    if "$@" >/dev/null 2>&1; then
        echo "ok: success [$*]"
    else
        echo "FAIL: expected success [$*]"
        TESTS_FAILED=$((TESTS_FAILED+1))
    fi
}

assert_fail() { # cmd...
    TESTS_RUN=$((TESTS_RUN+1))
    if "$@" >/dev/null 2>&1; then
        echo "FAIL: expected failure [$*]"
        TESTS_FAILED=$((TESTS_FAILED+1))
    else
        echo "ok: failed as expected [$*]"
    fi
}

finish() {
    echo "----"
    echo "${TESTS_RUN} run, ${TESTS_FAILED} failed"
    [ "$TESTS_FAILED" -eq 0 ]
}
```

- [ ] **Step 2: 写失败测试 `tests/test_sourceable.sh`**

```bash
#!/usr/bin/env bash
# 验证脚本可被 source 而不执行 main / 不触发前置退出,且关键函数已定义。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/assert.sh"

# source 不应退出当前 shell,也不应打印 ASCII 欢迎语(main 未执行)
out="$(source "$HERE/../linux_bench.sh" 2>&1; echo "SOURCED_OK")"
assert_contains "$out" "SOURCED_OK" "source 脚本后控制权应返回(main 未自动执行)"

# 关键函数在 source 后应已定义
( source "$HERE/../linux_bench.sh" 2>/dev/null
  declare -F preflight_checks >/dev/null ) && echo "ok: preflight_checks 已定义" || { echo "FAIL: preflight_checks 未定义"; }

( source "$HERE/../linux_bench.sh" 2>/dev/null
  declare -F retry_download >/dev/null ) && echo "ok: retry_download 已定义" || { echo "FAIL: retry_download 未定义"; }

finish
```

- [ ] **Step 3: 运行测试,确认失败**

Run: `bash tests/test_sourceable.sh`
Expected: 因为脚本当前一旦 source 就会执行 `main`(打印 ASCII、`sleep`、甚至前置 `exit`),`SOURCED_OK` 不会出现或卡住 → FAIL。

- [ ] **Step 4: 把前置检查移入 `preflight_checks()`**

在 `linux_bench.sh` 顶部,把这段(`uname`/`os-release`/`ID`/root 四个检查):

```bash
# =========================
# 系统检查
# =========================
if [ "$(uname)" != "Linux" ]; then
    echo "错误: 本脚本仅允许在 Linux 系统上执行。"
    exit 1
fi
# ... 直到 root 检查结束的 fi ...
```

改写为定义一个函数(放在 `# 配置 & 全局变量` 之前):

```bash
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
```

- [ ] **Step 5: 在 `main()` 开头调用 `preflight_checks`**

在 `main()` 函数体第一行(`clear` 之前)插入:

```bash
main() {
    preflight_checks
    clear
```

> 注:`collect_system_info` 用到的 `$PRETTY_NAME` 由 `preflight_checks` 内的 `source /etc/os-release` 设置为全局变量,执行路径下行为不变。

- [ ] **Step 6: 给底部 `main` 调用加 source 守卫**

把脚本最后一行:

```bash
main
```

改为:

```bash
# 仅在脚本被直接执行时运行 main;被 source 时只定义函数(便于测试)。
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

- [ ] **Step 7: 写汇总运行器 `tests/run_all.sh`**

```bash
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
```

- [ ] **Step 8: 运行测试,确认通过**

Run: `bash tests/test_sourceable.sh && bash -n linux_bench.sh`
Expected: 测试全部 `ok`,`finish` 输出 `... 0 failed`;`bash -n` 无输出(语法 OK)。

- [ ] **Step 9: 提交**

```bash
git add linux_bench.sh tests/assert.sh tests/run_all.sh tests/test_sourceable.sh
git commit -m "test: make script sourceable and add bash test harness"
```

---

## Task 2: 删除陈旧副本 `linux_bench.old.sh` (L1)

**Files:**
- Delete: `linux_bench.old.sh`

**Interfaces:** 无。已核验该文件全仓无任何引用。

- [ ] **Step 1: 确认无引用**

Run: `grep -rn "linux_bench.old" --include='*.sh' --include='*.md' --include='*.yml' .`
Expected: 无输出(无任何引用)。

- [ ] **Step 2: 删除文件**

Run: `git rm linux_bench.old.sh`
Expected: `rm 'linux_bench.old.sh'`。

- [ ] **Step 3: 验证主脚本与测试不受影响**

Run: `bash -n linux_bench.sh && bash tests/test_sourceable.sh`
Expected: 语法 OK,测试通过。

- [ ] **Step 4: 提交**

```bash
git commit -m "chore: remove stale duplicate linux_bench.old.sh"
```

---

## Task 3: 移除硬编码 NextTrace JWT Token (S3)

**背景:** `ensure_dependencies` 内 `export NEXTTRACE_TOKEN=$(echo "ZXlK..." | base64 -d)` 把一个 HS256 JWT 硬编码进公开仓库。base64 非加密。**代码层**:删除硬编码,改为尊重用户环境变量。**人工层**(附录 A):轮换该 token 并清除 git 历史。

**Files:**
- Modify: `linux_bench.sh`(`ensure_dependencies` 中 ~473 那行;新增 `setup_nexttrace_token`)
- Create: `SECURITY.md`
- Create: `tests/test_token.sh`

**Interfaces:**
- Produces: `setup_nexttrace_token()` —— 若环境已设 `NEXTTRACE_TOKEN` 则保留并 `export`,否则不设置(nexttrace 以无 token 模式运行)。

- [ ] **Step 1: 写失败测试 `tests/test_token.sh`**

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/assert.sh"
source "$HERE/../linux_bench.sh" 2>/dev/null

# 1) 用户提供的 token 必须被保留
export NEXTTRACE_TOKEN="user-provided-token"
setup_nexttrace_token
assert_eq "${NEXTTRACE_TOKEN:-}" "user-provided-token" "应保留用户提供的 NEXTTRACE_TOKEN"

# 2) 未提供时不应被硬编码值填充
unset NEXTTRACE_TOKEN
setup_nexttrace_token
assert_eq "${NEXTTRACE_TOKEN:-EMPTY}" "EMPTY" "未提供时不应注入硬编码 token"

# 3) 源码中不得再含 base64 token 大 blob 的前缀(当前文件中该 blob 以 ZXlKaGJHY2lP 开头)
assert_fail grep -q "ZXlKaGJHY2lP" "$HERE/../linux_bench.sh"

finish
```

> 注:`ZXlKaGJHY2lP` 是当前 `linux_bench.sh` 第 ~473 行硬编码 base64 token 的真实前缀(解码为 JWT 头)。T3 删除该行后,`assert_fail grep` 应找不到它 → 断言"已删除"成立。

- [ ] **Step 2: 运行测试,确认失败**

Run: `bash tests/test_token.sh`
Expected: `setup_nexttrace_token` 未定义 → 报错/FAIL。

- [ ] **Step 3: 删除硬编码行,新增 `setup_nexttrace_token` 并调用**

在 `ensure_dependencies` 中,定位下载 nexttrace 成功分支末尾的这行(约 473):

```bash
        # 设置 NextTrace Token
        export NEXTTRACE_TOKEN=$(echo "ZXlKaGJHY2lP...(长 base64)...QWMK" | base64 -d 2>/dev/null)
```

替换为:

```bash
        # 设置 NextTrace Token(不再硬编码;尊重用户环境变量)
        setup_nexttrace_token
```

并在工具函数区(`check_cmd` 附近)新增:

```bash
# NextTrace Token:不再硬编码。若用户通过环境变量提供则使用之,
# 否则 nexttrace 以无 token 模式运行(地理数据可能受限)。
setup_nexttrace_token() {
    if [ -n "${NEXTTRACE_TOKEN:-}" ]; then
        export NEXTTRACE_TOKEN
    fi
}
```

- [ ] **Step 4: 运行测试,确认通过**

Run: `bash tests/test_token.sh && bash -n linux_bench.sh`
Expected: 三个断言 `ok`;`finish` 0 failed;语法 OK。

- [ ] **Step 5: 写 `SECURITY.md` 记录人工动作**

```markdown
# 安全说明

## 凭据
- 历史版本曾在 `linux_bench.sh` 中硬编码 NextTrace API token(已于本次加固移除)。
  该 token 必须被视为**已泄露**:请在 NextTrace 侧**轮换/吊销**,并用
  `git filter-repo --replace-text` 或 BFG 从 git 历史中清除。
- 现在 NextTrace token 仅通过环境变量 `NEXTTRACE_TOKEN` 提供(可选)。

## 下载完整性
- 所有外部二进制/脚本下载均经 `download_and_verify`,对照 `utils/checksums.txt`
  做 sha256 校验。新增/升级工具时需同步更新该文件(见 utils/checksums.txt 顶部说明)。
```

- [ ] **Step 6: 提交**

```bash
git add linux_bench.sh tests/test_token.sh SECURITY.md
git commit -m "fix: remove hardcoded NextTrace token; honor env var (S3)"
```

> ⚠️ **人工后续(不在代码内,见附录 A):** 立即在 NextTrace 侧轮换该 token,并清除 git 历史。

---

## Task 4: 下载校验函数 `download_and_verify` (S1 之一)

**背景:** 现有 `retry_download` 只下载不校验,且 `$extra_args` 以未引用字符串靠词分割传参。本任务新增带 sha256 校验的下载函数,并把 `extra_args` 改为**数组**(顺带修一个引号隐患)。

**Files:**
- Modify: `linux_bench.sh`(`retry_download`;新增 `_sha256` 与 `download_and_verify`)
- Create: `tests/test_download_verify.sh`
- Create: `tests/fixtures/sample.bin`

**Interfaces:**
- Produces: `_sha256 <file>` —— 打印文件的 sha256 十六进制(优先 `sha256sum`,回退 `shasum -a 256`)。
- Produces: `download_and_verify <url> <out_file> <expected_sha256> [name] [curl_extra_args...]` —— 下载(复用重试)后校验 sha256;匹配返回 0,否则删除产物并返回 1。`expected_sha256` 为空字符串时**跳过校验并返回非 0**(强制调用方提供哈希)。
- Changes: `retry_download` 的第 4 参数 `extra_args` 仍接受字符串(向后兼容),但内部转为数组传给 curl。

- [ ] **Step 1: 造夹具**

```bash
mkdir -p tests/fixtures
printf 'linux_bench download-verify fixture\n' > tests/fixtures/sample.bin
```

- [ ] **Step 2: 写失败测试 `tests/test_download_verify.sh`**

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/assert.sh"
source "$HERE/../linux_bench.sh" 2>/dev/null

FIX="$HERE/fixtures/sample.bin"
TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_OUT"' EXIT

# 用与实现一致的方式计算期望哈希(兼容 mac/Linux)
good="$(_sha256 "$FIX")"
bad="0000000000000000000000000000000000000000000000000000000000000000"

# 1) 正确哈希 -> 成功,且产物存在
assert_success download_and_verify "file://$FIX" "$TMP_OUT" "$good" "fixture"
assert_eq "$(_sha256 "$TMP_OUT")" "$good" "下载产物内容应与夹具一致"

# 2) 错误哈希 -> 失败,且产物被删除
download_and_verify "file://$FIX" "$TMP_OUT" "$bad" "fixture" 2>/dev/null
assert_eq "$([ -f "$TMP_OUT" ] && echo exists || echo gone)" "gone" "哈希不匹配时应删除产物"

# 3) 空期望哈希 -> 必须失败(强制提供哈希)
assert_fail download_and_verify "file://$FIX" "$TMP_OUT" "" "fixture"

finish
```

- [ ] **Step 3: 运行测试,确认失败**

Run: `bash tests/test_download_verify.sh`
Expected: `_sha256` / `download_and_verify` 未定义 → FAIL。

- [ ] **Step 4: 实现 `_sha256` 与 `download_and_verify`,并把 `retry_download` 的 extra_args 改数组**

在 `retry_download` 之前新增:

```bash
# 计算文件 sha256(优先 sha256sum,回退 shasum -a 256)
_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    else
        shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    fi
}
```

把 `retry_download` 内两处 `curl -f -L -s $extra_args -o "$output_file" "$url"` 改为数组形式。函数开头:

```bash
retry_download() {
    local output_file="$1"
    local url="$2"
    local name="${3:-文件}"
    # extra_args 兼容旧的"字符串"调用,内部转数组,避免未引用词分割隐患
    local -a extra=()
    [ -n "${4:-}" ] && read -r -a extra <<< "$4"
```

两处 curl 改为:

```bash
            if curl -f -L -s "${extra[@]}" -o "$output_file" "$url" 2>/dev/null; then
```

在 `retry_download` 之后新增:

```bash
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
```

- [ ] **Step 5: 运行测试,确认通过**

Run: `bash tests/test_download_verify.sh && bash -n linux_bench.sh`
Expected: 全部 `ok`,0 failed;语法 OK。

- [ ] **Step 6: shellcheck 新函数(若已安装)**

Run: `command -v shellcheck >/dev/null && shellcheck -s bash <(sed -n '/^_sha256()/,/^}/p;/^download_and_verify()/,/^}/p' linux_bench.sh) || echo "shellcheck 未安装,跳过"`
Expected: 无 error 级告警(info/style 可接受)。

- [ ] **Step 7: 提交**

```bash
git add linux_bench.sh tests/test_download_verify.sh tests/fixtures/sample.bin
git commit -m "feat: add download_and_verify with sha256 check; arrayify curl args (S1)"
```

---

## Task 5: 固定版本 + 接入校验和到所有工具下载 (S1 之二)

**背景:** 把 nexttrace / yt-dlp / cloudflare-speed-cli / iNetSpeed / geekbench6 / RegionRestrictionCheck `check.sh` 全部改为**固定版本** + 经 `download_and_verify` 校验。期望哈希集中存放于 `utils/checksums.txt`,由 maintainer 用附录 B 的命令一次性采集。

> **关于哈希的"非占位"说明:** sha256 是环境事实,无法在计划里凭空写死。本任务提供**确定的采集流程**(附录 B)与**确定的代码结构**;Step 2 要求把采集到的真实哈希填入 `utils/checksums.txt`。这不是 "TODO",而是一次性数据录入。

**Files:**
- Create: `utils/checksums.txt`
- Modify: `linux_bench.sh`(`ensure_dependencies` 各下载块;`run_stream_test` 的 check.sh 下载块)

**Interfaces:**
- Consumes: `download_and_verify`(T4)。
- Produces: `get_expected_sha256 <key>` —— 从 `utils/checksums.txt` 读某 key 的期望哈希(未命中返回空串)。
- Produces: 固定版本变量 `NEXTTRACE_VERSION`、`YTDLP_VERSION`、`CFSPEED_VERSION`、`INETSPEED_VERSION`(=`v1.0.9`)、`GB6_VERSION`(=`6.5.0`)、`STREAM_CHECK_REF`。

- [ ] **Step 1: 建 `utils/checksums.txt` 骨架**

```text
# 外部工具校验和清单 (sha256)
# 格式: <sha256>  <key>
# key 约定: <tool>-<version>-<arch>  (arch: amd64/arm64,或与下载文件名一致)
# 采集方法见 docs/superpowers/plans/2026-06-29-linux-bench-security-hardening.md 附录 B
# ⚠️ 升级版本时必须同步更新本文件,否则该工具会因校验失败而跳过。

# nexttrace-<ver>-amd64  <填入>
# nexttrace-<ver>-arm64  <填入>
# yt-dlp-<ver>           <填入>
# cfspeed-<ver>-amd64    <填入>
# cfspeed-<ver>-arm64    <填入>
# inetspeed-v1.0.9-amd64 <填入>
# inetspeed-v1.0.9-arm64 <填入>
# geekbench-6.5.0-amd64  <填入>
# geekbench-6.5.0-arm64  <填入>
# regionrestrict-<ref>   <填入>
```

- [ ] **Step 2: 按附录 B 采集真实哈希并填入 `utils/checksums.txt`**

在一台可信机器上对每个固定版本运行附录 B 的命令,得到 `<sha256>  <key>` 行,**取消注释并填入真实值**。优先使用上游官方发布的校验和(yt-dlp 有 `SHA2-256SUMS`,nexttrace 有 `checksums.txt`);无官方校验和者(geekbench)采用 TLS 下"首次信任"(TOFU)记录。

- [ ] **Step 3: 新增 `get_expected_sha256` 读取函数**

放在 `download_and_verify` 之后:

```bash
# 从 utils/checksums.txt 读取某 key 的期望 sha256(打印;未命中为空)。
# 运行期该文件可能不存在(脚本是单文件分发),因此找不到时返回空,
# 由 download_and_verify 拒绝未校验下载。
get_expected_sha256() {
    local key="$1"
    local f="${CHECKSUMS_FILE:-}"
    [ -n "$f" ] && [ -f "$f" ] || return 0
    awk -v k="$key" '$0 !~ /^#/ && $2 == k { print $1; exit }' "$f"
}
```

并在全局变量区设置(紧邻 `TMP_DIR` 定义后):

```bash
# 校验和清单路径(与脚本同目录;curl|bash 单文件分发时可能不存在)
CHECKSUMS_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/utils/checksums.txt"
```

> **单文件分发注意:** 通过 `bash <(curl ...)` 运行时 `utils/checksums.txt` 不在本地,`get_expected_sha256` 返回空 → `download_and_verify` 会**拒绝**下载。因此本任务 Step 8 增加一条 fallback:校验和文件缺失时,从固定 raw URL 拉取 `checksums.txt` 到 `$TMP_DIR` 再用。

- [ ] **Step 4: 固定版本变量**

在 `ensure_dependencies` 的"实际下载"区之前,集中声明版本(就近原有逻辑):

```bash
    local NEXTTRACE_VERSION="v1.4.0"   # 采集哈希后,改为你校验过的稳定 tag
    local YTDLP_VERSION="2025.01.15"   # 同上,改为你校验过的 release tag
    local CFSPEED_VERSION="v0.2.0"     # 同上
    local INETSPEED_VERSION="v1.0.9"   # 现已固定
    local GB6_VERSION="6.5.0"          # 现已固定
```

> 这些示例值是**结构占位的版本号**:实现者在附录 B 采集哈希时确定当前稳定版本,并让此处版本号与 `utils/checksums.txt` 的 key 一致。这是一次性配置,不是 "TODO"。

- [ ] **Step 5: 改 nexttrace 下载块用固定版本 + 校验**

把:

```bash
        [ "$arch" == "x86_64" ] && url="https://github.com/nxtrace/NTrace-core/releases/latest/download/nexttrace_linux_amd64"
        [ "$arch" == "aarch64" ] && url="https://github.com/nxtrace/NTrace-core/releases/latest/download/nexttrace_linux_arm64"

        echo -n "  ├─ 正在下载 nexttrace..."
        if [ -n "$url" ] && retry_download "$TMP_DIR/nexttrace" "$url" "nexttrace"; then
```

改为:

```bash
        local nt_key=""
        [ "$arch" == "x86_64" ] && { url="https://github.com/nxtrace/NTrace-core/releases/download/${NEXTTRACE_VERSION}/nexttrace_linux_amd64"; nt_key="nexttrace-${NEXTTRACE_VERSION}-amd64"; }
        [ "$arch" == "aarch64" ] && { url="https://github.com/nxtrace/NTrace-core/releases/download/${NEXTTRACE_VERSION}/nexttrace_linux_arm64"; nt_key="nexttrace-${NEXTTRACE_VERSION}-arm64"; }

        echo -n "  ├─ 正在下载 nexttrace..."
        if [ -n "$url" ] && download_and_verify "$url" "$TMP_DIR/nexttrace" "$(get_expected_sha256 "$nt_key")" "nexttrace"; then
```

- [ ] **Step 6: 同样改 yt-dlp / cf-speed / inetspeed / geekbench6 下载块**

对每个工具,遵循同一模式:(a) URL 用固定版本而非 `latest`;(b) 计算 `key`;(c) 把 `retry_download ...` 换成 `download_and_verify "$url" "$out" "$(get_expected_sha256 "$key")" "<name>"`。压缩包类(cf-speed/geekbench)校验的是**压缩包**,解压逻辑不变。

yt-dlp:

```bash
        if download_and_verify "https://github.com/yt-dlp/yt-dlp/releases/download/${YTDLP_VERSION}/yt-dlp" "$TMP_DIR/yt-dlp" "$(get_expected_sha256 "yt-dlp-${YTDLP_VERSION}")" "yt-dlp"; then
```

cf-speed(主源/备源都用同一 key 校验,自建源被篡改也会被拒):

```bash
            if download_and_verify "$cf_url_primary" "$cf_tarball" "$(get_expected_sha256 "cfspeed-${CFSPEED_VERSION}-${cf_arch_key}")" "cf-speed"; then
                download_success=true
            else
                echo -n " (使用 GitHub)..."
                if download_and_verify "$cf_url_fallback" "$cf_tarball" "$(get_expected_sha256 "cfspeed-${CFSPEED_VERSION}-${cf_arch_key}")" "cf-speed (GitHub)"; then
                    download_success=true
                fi
            fi
```

(其中 `cf_arch_key` 为 `amd64`/`arm64`,在 `case "$arch"` 分支里赋值;geekbench 同理用 `gb_arch_key`。)

inetspeed、geekbench 按相同结构替换。**注意**:URL 里 `file.lowendaff.com` 主源保留作为加速,但**与官方源共用同一期望哈希**,从而即便自建源被改也会被拒绝。

- [ ] **Step 7: 改 `run_stream_test` 的 check.sh 用固定 ref + 校验**

把:

```bash
    local stream_script_url="https://github.com/1-stream/RegionRestrictionCheck/raw/main/check.sh"
    ...
    if ! retry_download "$stream_script_file" "$stream_script_url" "测试脚本"; then
```

改为:

```bash
    local STREAM_CHECK_REF="<commit-sha>"   # 固定到你审阅并校验过的 commit
    local stream_script_url="https://github.com/1-stream/RegionRestrictionCheck/raw/${STREAM_CHECK_REF}/check.sh"
    ...
    if ! download_and_verify "$stream_script_url" "$stream_script_file" "$(get_expected_sha256 "regionrestrict-${STREAM_CHECK_REF}")" "测试脚本"; then
```

> 注:校验在 `sed` 改写**之前**进行(下载即校验,改写只发生在校验通过后),保持现有 `sed` 行位置不变(在 `download_and_verify` 成功分支之后)。

- [ ] **Step 8: 单文件分发 fallback —— 校验和文件缺失时拉取**

在 `ensure_dependencies` 开头(`mkdir -p "$TMP_DIR"` 之后)加入:

```bash
    # curl|bash 单文件运行时本地没有 utils/checksums.txt,尝试拉取到临时目录
    if [ ! -f "$CHECKSUMS_FILE" ]; then
        if retry_download "$TMP_DIR/checksums.txt" "https://raw.githubusercontent.com/Lowendaff/linux_bench/main/utils/checksums.txt" "checksums" "--connect-timeout 5 --max-time 15"; then
            CHECKSUMS_FILE="$TMP_DIR/checksums.txt"
        fi
    fi
```

> 安全权衡(写入 SECURITY.md):此 fallback 的信任根是 `raw.githubusercontent.com` 的 TLS + 仓库内容。它把"信任二进制源"收敛为"信任 GitHub 上的校验和文件",显著优于现状(完全不校验),但仍假设 GitHub 仓库未被攻陷。

- [ ] **Step 9: 静态门禁 + 结构自检**

Run:
```bash
bash -n linux_bench.sh && \
echo "--- 仍在用 latest 的下载(应为空):" && \
grep -n "releases/latest" linux_bench.sh || echo "  无 latest 残留 ✓"
```
Expected: 语法 OK;`releases/latest` 无残留(全部改为固定版本)。

- [ ] **Step 10: 手动冒烟(无法单元测试,见附录 B)**

在一次性 VPS 上跑 `sudo ./linux_bench.sh --speedtest`(触发 cf-speed/inetspeed 下载)与 `-t`(nexttrace/yt-dlp),确认:校验通过则正常下载;故意把 `utils/checksums.txt` 改错一位 → 对应工具应"校验失败 → 跳过",脚本继续不崩。

- [ ] **Step 11: 提交**

```bash
git add linux_bench.sh utils/checksums.txt
git commit -m "feat: pin tool versions and verify sha256 on all downloads (S1)"
```

---

## Task 6: 加固 `--fix-dns` 的 resolv.conf 覆盖/恢复 (H1)

**背景:** 现状在 SIGKILL/断电时不恢复;且 `/etc/resolv.conf` 常是指向 systemd-resolved 的符号链接,`cp -L` 备份 + `cat >` 恢复会破坏链接;失败全程静默。抽成可测函数,处理符号链接,恢复失败要告警。

**Files:**
- Modify: `linux_bench.sh`(`main` 的 `--fix-dns` 块 ~3211-3217;`cleanup` 的 DNS 恢复 ~240-244;新增两个函数 + 全局状态变量)
- Create: `tests/test_dns_restore.sh`

**Interfaces:**
- Produces: `apply_dns_override [resolv_path]` —— 记录原状态(是否符号链接及其目标)、备份内容到 `$TMP_DIR/resolv.conf.bak`、写入公共 DNS;成功设 `DNS_OVERRIDE_APPLIED=true` 返回 0,失败 `warn` 并返回 1。
- Produces: `restore_dns_override [resolv_path]` —— 若曾覆盖:符号链接则用 `ln -sf` 还原,否则从备份 `cp` 还原;失败 `warn`。幂等(未覆盖时直接返回 0)。
- 全局: `DNS_OVERRIDE_APPLIED`、`DNS_ORIG_WAS_SYMLINK`、`DNS_ORIG_SYMLINK_TARGET`。
- 参数化 `resolv_path`(默认 `/etc/resolv.conf`)使测试不触碰真实系统文件。

- [ ] **Step 1: 写失败测试 `tests/test_dns_restore.sh`**

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/assert.sh"
source "$HERE/../linux_bench.sh" 2>/dev/null

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export TMP_DIR="$WORK/tmp"; mkdir -p "$TMP_DIR"

# 场景 A:普通文件
resolv="$WORK/resolv_regular"
printf 'nameserver 192.0.2.1\n' > "$resolv"
DNS_OVERRIDE_APPLIED=false
apply_dns_override "$resolv"
assert_contains "$(cat "$resolv")" "1.1.1.1" "覆盖后应包含公共 DNS"
restore_dns_override "$resolv"
assert_eq "$(cat "$resolv")" "nameserver 192.0.2.1" "普通文件应被完整还原"

# 场景 B:符号链接(模拟 systemd-resolved stub)
target="$WORK/stub-resolv.conf"
printf 'nameserver 127.0.0.53\n' > "$target"
linkpath="$WORK/resolv_symlink"
ln -s "$target" "$linkpath"
rm -f "$TMP_DIR/resolv.conf.bak"
DNS_OVERRIDE_APPLIED=false
apply_dns_override "$linkpath"
assert_contains "$(cat "$linkpath")" "1.1.1.1" "覆盖后(经链接或替换)应含公共 DNS"
restore_dns_override "$linkpath"
assert_eq "$([ -L "$linkpath" ] && echo symlink || echo file)" "symlink" "原为符号链接应还原为符号链接"
assert_eq "$(readlink "$linkpath")" "$target" "符号链接目标应还原"

# 场景 C:幂等 —— 未覆盖时 restore 不报错
DNS_OVERRIDE_APPLIED=false
assert_success restore_dns_override "$resolv"

finish
```

- [ ] **Step 2: 运行,确认失败**

Run: `bash tests/test_dns_restore.sh`
Expected: 函数未定义 → FAIL。

- [ ] **Step 3: 在全局变量区新增状态变量**

紧随其他运行标志(如 `FIX_DNS=false` 之后):

```bash
# DNS 覆盖状态(用于精确恢复)
DNS_OVERRIDE_APPLIED=false
DNS_ORIG_WAS_SYMLINK=false
DNS_ORIG_SYMLINK_TARGET=""
```

- [ ] **Step 4: 实现两个函数**

放在 `cleanup` 之前:

```bash
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
    # 若是符号链接,先删除以免写穿到 stub 目标
    [ -L "$resolv" ] && rm -f "$resolv" 2>/dev/null
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
```

- [ ] **Step 5: 在 `main` 中用 `apply_dns_override` 替换内联块**

把:

```bash
    if [ "$FIX_DNS" = "true" ]; then
        mkdir -p "$TMP_DIR"
        if [ -f /etc/resolv.conf ]; then
            cp -L /etc/resolv.conf "$TMP_DIR/resolv.conf.bak" 2>/dev/null || true
        fi
        echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 2606:4700:4700::1111" > /etc/resolv.conf 2>/dev/null || true
        log "${YELLOW}应用: 强制临时覆盖系统 DNS (--fix-dns)${NC}"
    fi
```

改为:

```bash
    if [ "$FIX_DNS" = "true" ]; then
        mkdir -p "$TMP_DIR"
        if apply_dns_override; then
            log "${YELLOW}应用: 强制临时覆盖系统 DNS (--fix-dns)${NC}"
        fi
    fi
```

- [ ] **Step 6: 在 `cleanup` 中用 `restore_dns_override` 替换内联恢复**

把:

```bash
    # 0.5 恢复 DNS
    if [ "$FIX_DNS" = "true" ] && [ -f "$TMP_DIR/resolv.conf.bak" ]; then
        echo "  ├─ 恢复系统 DNS 配置..."
        cat "$TMP_DIR/resolv.conf.bak" > /etc/resolv.conf 2>/dev/null || true
    fi
```

改为:

```bash
    # 0.5 恢复 DNS
    if [ "$DNS_OVERRIDE_APPLIED" = "true" ]; then
        echo "  ├─ 恢复系统 DNS 配置..."
        restore_dns_override
    fi
```

- [ ] **Step 7: 运行测试 + 语法**

Run: `bash tests/test_dns_restore.sh && bash -n linux_bench.sh`
Expected: 三场景全部 `ok`,0 failed;语法 OK。

- [ ] **Step 8: 提交**

```bash
git add linux_bench.sh tests/test_dns_restore.sh
git commit -m "fix: robust --fix-dns override/restore incl. symlink & failure warnings (H1)"
```

---

## Task 7: `TMP_DIR` 改用 `mktemp -d` (H3)

**背景:** `TMP_DIR="./tmp_bench_$(date +%s)"` 是 CWD 相对路径且可预测。改用 `mktemp -d`。所有引用都用 `$TMP_DIR`,故只需改定义点 + 移除后续多余 `mkdir -p`(保留亦无害,mktemp 已建好)。

**Files:**
- Modify: `linux_bench.sh`(`TMP_DIR` 定义 ~47)

**Interfaces:** 无新接口。`TMP_DIR` 仍是全局变量,值改为绝对临时目录。

- [ ] **Step 1: 改定义**

把:

```bash
TMP_DIR="./tmp_bench_$(date +%s)"
```

改为:

```bash
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/linux_bench.XXXXXX")"
```

- [ ] **Step 2: 确认 source 后 TMP_DIR 合法(快速断言)**

Run:
```bash
bash -c 'source ./linux_bench.sh 2>/dev/null; case "$TMP_DIR" in /*) echo "ABS_OK $TMP_DIR";; *) echo "BAD $TMP_DIR";; esac; [ -d "$TMP_DIR" ] && echo DIR_OK'
```
Expected: `ABS_OK /tmp/linux_bench.XXXXXX` 且 `DIR_OK`(EXIT trap 随后会清理该目录)。

- [ ] **Step 3: 语法门禁**

Run: `bash -n linux_bench.sh && bash tests/run_all.sh`
Expected: 语法 OK;既有测试仍全绿。

- [ ] **Step 4: 提交**

```bash
git add linux_bench.sh
git commit -m "fix: use mktemp -d for TMP_DIR instead of predictable CWD path (H3)"
```

---

## Task 8: 整数/数字输入校验 (H4)

**背景:** `[ "$x" -eq/-lt N ]` 在 `x` 为空或小数时报 `integer expression expected` 并静默判假。新增 `is_uint`/`is_num`,在 4 个站点加固;`format_fraud_score` 改用 `awk` 比较以支持小数。

**Files:**
- Modify: `linux_bench.sh`(新增 `is_uint`/`is_num`;`collect_system_info` swap ~700;`run_cpu_test` ~1265;`run_gb6_test` ~1310-1313;`format_fraud_score` ~1067-1080)
- Create: `tests/test_int_validation.sh`

**Interfaces:**
- Produces: `is_uint <s>` —— `s` 为非负整数返回 0 否则非 0。
- Produces: `is_num <s>` —— `s` 为非负整数或小数返回 0 否则非 0。
- Changes: `format_fraud_score` 对小数不再报错,按 `<40/<70/其余` 分桶。

- [ ] **Step 1: 写失败测试 `tests/test_int_validation.sh`**

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/assert.sh"
source "$HERE/../linux_bench.sh" 2>/dev/null

assert_success is_uint 42
assert_fail    is_uint ""
assert_fail    is_uint 12.5
assert_fail    is_uint abc
assert_success is_num 12.5
assert_success is_num 7
assert_fail    is_num ""

# format_fraud_score: 整数与小数都不应报错,分桶正确(输出形如 "值|评级")
assert_eq "$(format_fraud_score 10  | cut -d'|' -f2)" "🟢 低"  "10 -> 低"
assert_eq "$(format_fraud_score 12.5| cut -d'|' -f2)" "🟢 低"  "小数 12.5 -> 低(不报错)"
assert_eq "$(format_fraud_score 80  | cut -d'|' -f2)" "🔴 高"  "80 -> 高"
assert_eq "$(format_fraud_score ''  )" "N/A|—"               "空 -> N/A"

finish
```

- [ ] **Step 2: 运行,确认失败**

Run: `bash tests/test_int_validation.sh`
Expected: `is_uint` 未定义 / `format_fraud_score` 对小数报错 → FAIL。

- [ ] **Step 3: 新增校验函数**

放在 `calc` 附近:

```bash
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
is_num()  { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
```

- [ ] **Step 4: 改 `format_fraud_score` 用 awk 比较**

把分支:

```bash
        if [ "$score" -lt 40 ]; then
            echo "$score|🟢 低"
        elif [ "$score" -lt 70 ]; then
            echo "$score|🟡 中"
        else
            echo "$score|🔴 高"
        fi
```

改为:

```bash
        if ! is_num "$score"; then echo "N/A|—"; return; fi
        local bucket
        bucket="$(awk -v s="$score" 'BEGIN{ if (s<40) print "low"; else if (s<70) print "mid"; else print "high" }')"
        case "$bucket" in
            low)  echo "$score|🟢 低" ;;
            mid)  echo "$score|🟡 中" ;;
            *)    echo "$score|🔴 高" ;;
        esac
```

(其上方原有的 `if [ -z "$score" ] || [ "$score" = "null" ]` 空值判断保留。)

- [ ] **Step 5: 加固另外三处整数比较**

- `collect_system_info`(swap):把 `if [ "$swap_total" -eq 0 ]` 前加默认化 —— 在赋值后插入 `is_uint "$swap_total" || swap_total=0`。
- `run_cpu_test`:把 `if [ "$SYS_CORES" -gt 1 ]` 改为 `if is_uint "$SYS_CORES" && [ "$SYS_CORES" -gt 1 ]`。
- `run_gb6_test`:在 `local total_mb=$((mem_total_mb + swap_total_mb))` 前,对两个加数默认化:`is_uint "$mem_total_mb" || mem_total_mb=0` 和 `is_uint "$swap_total_mb" || swap_total_mb=0`。

- [ ] **Step 6: 运行测试 + 语法**

Run: `bash tests/test_int_validation.sh && bash -n linux_bench.sh`
Expected: 全部 `ok`,0 failed;语法 OK。

- [ ] **Step 7: 提交**

```bash
git add linux_bench.sh tests/test_int_validation.sh
git commit -m "fix: validate numeric inputs before integer comparisons (H4)"
```

---

## Task 9: 锁定上游 check.sh + 解析失败告警 (H5)

> check.sh 的**版本锁定 + 校验**已在 T5 Step 7 完成。本任务补"解析失败不再静默"。

**Files:**
- Modify: `linux_bench.sh`(`run_stream_test` 报告生成后)

**Interfaces:** 无新公共接口;在 `run_stream_test` 末尾对"有原始输出但解析出 0 行服务"的情形 `warn`。

- [ ] **Step 1: 加解析结果计数与告警**

在 `run_stream_test` 内、`stream_output` 合并完成且非空之后(即现有 `info "  └─ 服务解锁测试完成"` 之前或之后),插入一个轻量自检:用 `parse_stream_to_table` 对 v4/v6 输出解析并统计**非分类行**数,若原始输出非空但解析行数为 0,则告警上游格式可能已变。

```bash
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
```

- [ ] **Step 2: 语法门禁 + 既有测试**

Run: `bash -n linux_bench.sh && bash tests/run_all.sh`
Expected: 语法 OK;既有测试全绿。

- [ ] **Step 3: 手动冒烟(可选)**

在一次性 VPS 上 `sudo ./linux_bench.sh -s`;再人为破坏(例如把 `parse_stream_to_table` 的分类正则临时改坏)以确认告警会触发。

- [ ] **Step 4: 提交**

```bash
git add linux_bench.sh
git commit -m "fix: warn when stream-unlock parsing yields nothing (H5)"
```

---

## Task 10: 零散修正 —— local / cleanup 幂等 / ping -6 (L5/L6/L8)

**Files:**
- Modify: `linux_bench.sh`(`run_trace_test` 的 `v4`/`v6` ~2643/2655;`cleanup` ~233;两处 `ping6` ~1662/1694)
- Create: `tests/test_cleanup_idempotent.sh`

**Interfaces:**
- Changes: `cleanup` 增加 `_CLEANED` 幂等守卫(被 EXIT 与 INT 双触发时只实际执行一次)。

- [ ] **Step 1: 写失败测试 `tests/test_cleanup_idempotent.sh`**

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/assert.sh"
source "$HERE/../linux_bench.sh" 2>/dev/null

# 用独立临时目录,避免影响真实环境
export TMP_DIR="$(mktemp -d)"
FIX_DNS=false
CLEANUP_PKGS=()
SPINNER_PID=""
unset _CLEANED 2>/dev/null || true

# 第一次 cleanup:应删除 TMP_DIR
cleanup
# 第二次:重建 TMP_DIR 与标记,若幂等守卫生效则不应再删除标记
mkdir -p "$TMP_DIR"; touch "$TMP_DIR/marker"
cleanup
assert_eq "$([ -f "$TMP_DIR/marker" ] && echo kept || echo removed)" "kept" "二次 cleanup 应被幂等守卫拦截"

rm -rf "$TMP_DIR"
finish
```

- [ ] **Step 2: 运行,确认失败**

Run: `bash tests/test_cleanup_idempotent.sh`
Expected: 当前 `cleanup` 无守卫,二次调用会再次 `rm -rf "$TMP_DIR"` 删除 marker → `removed` → FAIL。

- [ ] **Step 3: 给 `cleanup` 加幂等守卫**

在 `cleanup()` 函数体第一行加入:

```bash
cleanup() {
    [ -n "${_CLEANED:-}" ] && return 0
    _CLEANED=1
```

- [ ] **Step 4: `run_trace_test` 中 `v4`/`v6` 补 `local`**

把:

```bash
            v4=$("$YTDLP_BIN" $yt_args -4 "$yt_video" 2>"$yt_err" | head -n1 | awk -F/ '{print $3}')
```
```bash
            v6=$("$YTDLP_BIN" $yt_args -6 "$yt_video" 2>"$yt_err" | head -n1 | awk -F/ '{print $3}')
```

分别改为 `local v4=$(...)` 与 `local v6=$(...)`(在各自的 `if [ "$HAS_V4"... ]` / `if [ "$HAS_V6"... ]` 块内首次使用处声明)。

- [ ] **Step 5: `ping6` 改 `ping -6`**

把 `run_iperf_test` 内两处:

```bash
lat=$(ping6 -c 1 -W 1 "$host" ...)
```

改为:

```bash
lat=$(ping -6 -c 1 -W 1 "$host" ...)
```

(国际节点 IPv6 分支一处;国内节点若用 `ping`(IPv4)的保持不变 —— 仅替换 `ping6` 调用。)

- [ ] **Step 6: 运行测试 + 语法**

Run: `bash tests/test_cleanup_idempotent.sh && bash -n linux_bench.sh && grep -n "ping6" linux_bench.sh || echo "ping6 已清除 ✓"`
Expected: 幂等测试 `kept`、0 failed;语法 OK;`ping6` 无残留。

- [ ] **Step 7: 提交**

```bash
git add linux_bench.sh tests/test_cleanup_idempotent.sh
git commit -m "fix: local v4/v6, idempotent cleanup guard, ping -6 (L5/L6/L8)"
```

---

## Task 11: `set -o pipefail` + shellcheck 引导的引号加固 (H2)

**背景:** 最后做,风险最高。**仅启用 `set -o pipefail`**(不启用 `-e`/`-u` —— 脚本大量依赖 `cmd || true` 与可空变量,贸然开启会破坏行为)。再用 shellcheck 定位并修复**危险**的未引用展开(优先 SC2086 在安全敏感处),其余 cosmetic 告警可接受/抑制。

**Files:**
- Modify: `linux_bench.sh`(顶部加 `set -o pipefail`;若干引号修复)

**Interfaces:** 无新接口;行为门禁靠 `bash -n` + 全套单元测试 + 手动冒烟。

- [ ] **Step 1: 启用 pipefail**

在 shebang 与 GPL 头之后、`# 系统前置检查` 之前加入:

```bash
# 仅启用 pipefail:让管道中任一环失败都能被感知。
# 注意:有意不启用 set -e / set -u —— 脚本大量使用 `cmd || true` 与可空变量,
# 贸然开启会改变现有控制流。后续如需引入需配合完整回归(见 P2 路线图)。
set -o pipefail
```

- [ ] **Step 2: 运行全套单元测试,确认 pipefail 未破坏纯函数**

Run: `bash tests/run_all.sh`
Expected: 全部测试仍 0 failed(若有新失败,说明某纯函数依赖了管道"前段失败被忽略"的旧行为,就地修正)。

- [ ] **Step 3: shellcheck 全量扫描并分诊**

Run:
```bash
command -v shellcheck >/dev/null || { echo "请先安装 shellcheck: apt-get install -y shellcheck"; exit 0; }
shellcheck -s bash -S warning linux_bench.sh | tee /tmp/sc.txt
echo "=== 危险未引用(SC2086)出现次数:"; grep -c SC2086 /tmp/sc.txt
```
Expected: 得到告警清单。**分诊原则**:
- **必修**:命令参数中影响安全/正确性的未引用变量(如传给 `curl`/`bash`/`rm`/`tar` 的路径与 URL)。注意 `retry_download` 的 `extra` 已在 T4 数组化。
- **保持**:有意依赖词分割之处(如 `apt-get install -y -q $missing_pkgs`、`$target_pkgs` 循环)——给这些行加 `# shellcheck disable=SC2086` 并注释原因,而非强行加引号。
- **cosmetic**:纯展示 `echo` 里的未引用变量,低优先,可暂留。

- [ ] **Step 4: 修复"必修"项 + 标注"有意"项**

对每个必修项加引号;对有意词分割项加定向 `# shellcheck disable=SC2086 # 故意词分割: 包列表`。逐处修改后:

Run: `bash -n linux_bench.sh`
Expected: 语法 OK。

- [ ] **Step 5: 回归 —— 全套单元测试 + 手动冒烟**

Run: `bash tests/run_all.sh`
Expected: 0 failed。

手动冒烟(附录 B 环境):至少跑一次 `sudo ./linux_bench.sh --speedtest -4` 与 `sudo ./linux_bench.sh -h --skip-gb`,确认无新报错、报告正常生成。

- [ ] **Step 6: 提交**

```bash
git add linux_bench.sh
git commit -m "refactor: enable pipefail and harden dangerous unquoted expansions (H2)"
```

---

## 附录 A:人工动作(非代码,必须执行)

1. **轮换 NextTrace token**:在 NextTrace 侧吊销/重签历史泄露的 token。
2. **清除 git 历史中的 token**:
   ```bash
   # 用 git-filter-repo(推荐)把 blob 从所有历史提交中抹除
   pip install git-filter-repo
   git filter-repo --replace-text <(echo 'ZXlKaGJHУ***==>REDACTED')
   # 强推前先备份;协作者需重新 clone
   ```
3. **（可选,S2,本计划范围外)** 为分发提供带 tag 的 release + 校验和,并在 README 给出可校验安装方式。

## 附录 B:采集工具 sha256 的方法(供 T5 Step 2)

> 在一台**可信**机器上执行,把输出的哈希填入 `utils/checksums.txt`。优先用上游官方校验和;无官方者用 TLS 下 TOFU。

```bash
# 通用:下载后算 sha256(Linux 用 sha256sum;mac 用 shasum -a 256)
dl() { curl -fL --proto '=https' --tlsv1.2 -o "$2" "$1" && sha256sum "$2"; }

# 例:nexttrace amd64(把 <VER> 换成你固定的稳定 tag)
dl "https://github.com/nxtrace/NTrace-core/releases/download/<VER>/nexttrace_linux_amd64" /tmp/nt
#  -> 形如: <sha256>  /tmp/nt   取前面的 <sha256> 填入 nexttrace-<VER>-amd64

# yt-dlp 有官方 SHA2-256SUMS,直接核对:
curl -fsSL "https://github.com/yt-dlp/yt-dlp/releases/download/<VER>/SHA2-256SUMS" | grep -E '  yt-dlp$'

# nexttrace 官方 checksums.txt:
curl -fsSL "https://github.com/nxtrace/NTrace-core/releases/download/<VER>/checksums.txt"

# geekbench 无官方哈希 -> 用上面的 dl 在 TLS 下记录(TOFU),并在 SECURITY.md 注明
```

## 附录 C:手动冒烟检查清单(Linux/Debian 一次性 VPS)

| 命令 | 关注点 |
| :--- | :--- |
| `sudo ./linux_bench.sh -h --skip-gb` | CPU/磁盘;整数校验路径(H4) |
| `sudo ./linux_bench.sh --speedtest -4` | cf-speed/inetspeed 下载+校验(S1) |
| `sudo ./linux_bench.sh -t` | nexttrace/yt-dlp 下载+校验;无 token 运行(S3) |
| `sudo ./linux_bench.sh -s` | check.sh 锁定+校验;解析告警(H5) |
| `sudo ./linux_bench.sh -n --fix-dns` 后 `Ctrl-C` | DNS 恢复(H1);cleanup 不重复(L6) |
| 把 `utils/checksums.txt` 改错一位再跑 | 校验失败应"跳过"而非崩溃(S1) |

## 自检备注(已对照 spec)

- **覆盖**:S3→T3、S1→T4+T5、H1→T6、H3→T7、L1→T2、H4→T8、H5→T5+T9、L5/L6/L8→T10、H2→T11、测试基建→T1。S2 明确列为范围外(附录 A 第 3 条)。P2 不在本计划。
- **类型一致**:`download_and_verify(url,out,sha,name,extra)`、`get_expected_sha256(key)`、`_sha256(file)`、`is_uint/is_num`、`apply_dns_override/restore_dns_override([path])`、`setup_nexttrace_token()`、`cleanup` 的 `_CLEANED` —— 跨任务签名/命名一致。
- **占位**:sha256 与具体版本号通过附录 B 的确定流程录入 `utils/checksums.txt`,非 TODO。
