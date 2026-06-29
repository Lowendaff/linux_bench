# Linux Bench 代码审查报告

- **审查日期**：2026-06-29
- **审查范围**：全面审查（安全 / 正确性 / 健壮性 / 可维护性 / Python & CI）
- **被审对象**：`linux_bench.sh`（3281 行）、`utils/fetch_nf_ix_map.py`、`.github/workflows/fetch_nf_ix_map.yml`、`utils/*.txt` 数据文件
- **审查方式**：人工逐行通读主脚本 + 模式扫描 + 关键事实核验

---

## 0. 总体评价

这是一个**功能极其丰富、工程化程度却偏低**的项目。单文件 3281 行 Bash 实现了系统信息、CPU/磁盘跑分、多种测速、IP 质量、流媒体解锁、双向路由追踪等大量能力，作者对 shell 文本处理与各类测试工具的掌握很扎实，错误回退（重试、备用源、fallback 列表）也考虑得比较周到。

但作为一个**以 root 身份、通过 `curl | bash` 在他人服务器上运行**的脚本，它的**安全基线不达标**：最突出的问题是"下载任意二进制/脚本后直接以 root 执行，且全程零完整性校验"。这是本次审查的头号问题，其余问题按下文分级。

> ✅ 澄清（避免过度告警）：脚本中**没有可被利用的 shell 命令注入**。不可信数据（追踪目标、API 返回）都是作为**带引号的参数**传给 `nexttrace`/`jq`，没有 `eval`。真正的远程代码执行风险来自"下载即执行"的供应链设计，而非字符串拼接。

**严重程度分布**：🔴 严重 3 项 · 🟠 重要 5 项 · 🟡 次要 11 项

---

## 1. 🔴 严重问题（Critical / 安全）

### S1. 供应链 RCE：下载的二进制与脚本零完整性校验，且以 root 执行

脚本会下载以下外部产物，`chmod +x` 或 `bash` 后**直接以 root 运行**，**没有任何 sha256 / GPG 校验**（已核验全文无 `sha256/gpg/checksum` 校验逻辑）：

| 产物 | 位置 | 来源 | 版本固定？ |
| :--- | :--- | :--- | :--- |
| nexttrace | `460-466` | GitHub `releases/latest` | ❌ latest（可变） |
| yt-dlp | `481-483` | GitHub `releases/latest` | ❌ latest（可变） |
| cloudflare-speed-cli | `501-535` | **主源 `file.lowendaff.com`** / 备 GitHub latest | ❌ latest |
| iNetSpeed-CLI | `561-575` | GitHub `v1.0.9` | ✅ 但无校验 |
| Geekbench 6 | `596-629` | **主源 `file.lowendaff.com`** / 备官方 CDN | ✅ 6.5.0 但无校验 |
| RegionRestrictionCheck `check.sh` | `1987-2030` | GitHub raw `main`（再 `sed` 改写后 `bash`） | ❌ main 分支 HEAD |

**影响**：
- 多个产物的**主源是单一自建 CDN `file.lowendaff.com`**。一旦该主机被入侵或其 DNS 被劫持，攻击者可向**所有运行本脚本的服务器**投递恶意二进制并以 root 执行 → 全量 root 沦陷。
- `latest` / `main` 是**可变引用**，今天审计通过不代表明天下载到的还是同一文件。
- `check.sh` 是第三方脚本，被 `sed` 改写后以 root `bash` 执行，等同于把 root 权限托管给上游仓库的 HEAD。

**建议**：
1. **固定版本** + **校验和**：所有下载改为固定 tag/commit，并在执行前 `sha256sum -c` 校验预置的期望哈希；Geekbench 这类有官方签名的尽量用 GPG。
2. **官方源优先**：把 `file.lowendaff.com` 降为"加速备用源"，主源用上游官方地址，并对两者用**同一份期望哈希**校验（这样自建 CDN 即使被改也会被拒）。
3. `check.sh` 锁定到具体 commit SHA 并校验哈希，避免追 `main`。

---

### S2. 分发模型 `bash <(curl -L -s bench.lowendaff.com)` 以 root 运行且不可校验

`readme.md:40,58` 推荐的安装方式无法校验脚本本体，与 S1 叠加放大了风险面：用户既无法验证脚本本身，脚本又会无校验地拉取更多可执行体。

**建议**：提供**带 tag 的 release + 校验和**，并在文档给出可校验流程：
```bash
curl -fsSLo lb.sh https://.../vX.Y/linux_bench.sh
echo "<expected_sha256>  lb.sh" | sha256sum -c - && sudo bash lb.sh
```

---

### S3. 硬编码的 NextTrace JWT Token（凭据泄露）

`linux_bench.sh:473` 内嵌了一段 base64，解码后是一个 **HS256 JWT**（`{"alg":"HS256","typ":"JWT"}`），并 `export NEXTTRACE_TOKEN`。base64 只是**编码不是加密**，任何人都能从公开仓库提取该 token。

**影响**：token 可被任意提取并滥用（消耗配额 / 冒用身份）。已提交进 git 历史，单纯删除当前文件不够。

**建议**：
- **立即轮换**该 token。
- 若它本就是"共享免费 token"，在文档中明确声明其为公开值并接受被滥用的后果；否则改为运行期安全获取，并用 `git filter-repo` 等清除历史。

---

## 2. 🟠 重要问题（健壮性 / 安全副作用）

### H1. `--fix-dns` 覆盖 `/etc/resolv.conf`，异常退出 / 符号链接场景下不恢复
- 写入：`main:3211-3217`；恢复：`cleanup:240-244`。
- 恢复只发生在 `EXIT/INT/TERM` trap 中。**SIGKILL、断电、OOM 杀进程**时不会恢复 → 主机 DNS 被永久改坏。
- 现代系统 `/etc/resolv.conf` 常是指向 `systemd-resolved` stub 的**符号链接**。`cp -L` 备份的是链接目标内容，恢复时用 `cat > /etc/resolv.conf` 写成**普通文件**，破坏了原有符号链接语义；且全程 `|| true` **静默失败**。

**建议**：检测是否符号链接 / systemd-resolved；优先用 `resolvectl` 或 drop-in 配置；恢复失败必须显著告警；精确还原原始形态（含符号链接）。

### H2. 全程缺少 `set -euo pipefail`（已核验：无）
失败的 `mkdir` / 解析 / 命令会**静默继续**。对一个执行 `swapon`、改 DNS、`apt-get install/remove` 的 root 脚本，这会放大其他 bug 的后果。

> ⚠️ 注意：直接加 `set -e` 会与脚本里大量 `cmd || true`、允许失败的 `$(...)` 冲突，**不能盲目开启**。建议先上 `set -o pipefail`，并在关键副作用路径加显式检查；引入后需做完整回归测试（详见修复计划 P1）。

### H3. `TMP_DIR="./tmp_bench_$(date +%s)"` 相对路径 + 可预测（`linux_bench.sh:47`）
- 在**当前工作目录**创建。若 CWD 只读 / 异常，`mkdir -p`（`435`）失败而又无 `set -e` → 后续所有写入静默错乱；报告文件同样落在 CWD。
- 名称可预测（时间戳），共享 CWD 下存在符号链接预创建的边角风险。

**建议**：改用 `mktemp -d`；报告输出路径显式化（如 `$PWD` 或用户指定）。

### H4. 整数比较未校验数字输入
- `[ "$swap_total" -eq 0 ]`（`700`）、`[ "$SYS_CORES" -gt 1 ]`（`1265`）、`[ "$total_mb" -lt ... ]`（`1310-1313`）、`format_fraud_score` 的 `[ "$score" -lt 40 ]`（`1073`）。
- 当上游解析得到空串或**小数**（`fraudScore` 很可能是小数）时，`[ -lt ]` 会抛 `integer expression expected` 到 stderr，并将判定视为假 → **结果静默错误**。

**建议**：比较前用正则校验整数 / 默认 0；小数改用 `awk` 比较。

### H5. 流媒体解锁解析极其脆弱且失败时静默
`run_stream_test` 下载上游 `check.sh` 后用 `sed` 改写（`1999`），再依赖**精确的中文字符串与 ANSI 格式**做解析（`parse_stream_to_table`，`2162+`）。上游脚本一旦改动输出，解析就会**静默产出空表**（已经在 `sed` 修补上游 quirk，说明这种耦合已发生过）。

**建议**：锁定上游版本 / commit；解析失败时显式告警而非空表；尽量使用上游的结构化输出（若提供）。

---

## 3. 🟡 次要问题（可维护性 / 正确性 / 文档）

| # | 问题 | 位置 | 建议 |
| :-- | :--- | :--- | :--- |
| L1 | `linux_bench.old.sh`（3288 行）陈旧副本，全仓**无任何引用** | 仓库根 | 直接删除（已在 git 历史，可随时找回） |
| L2 | 3281 行**单体脚本**：30+ 函数、大量全局变量、函数内嵌套定义 | 全文 | 路线图级重构：拆 `lib/*.sh` 按职责分文件、隔离全局状态 |
| L3 | **大量复制粘贴** | 见下 | 抽公共函数 |
| L4 | `normalize_isp_name` 220+ 行顺序 `[[ ]] && {echo;return;}` | `2358-2580` | 改为**数据驱动查表**（关联数组 / 外部映射文件） |
| L5 | `v4` / `v6` 未声明 `local`，泄露为全局变量（同段 `nf` 是 local） | `2643, 2655` | 加 `local` |
| L6 | **双重 cleanup**：`interrupt_handler` 调 `cleanup` 后 `exit` → 再触发 `EXIT` trap 又跑一次 `cleanup`，`apt remove`/提示重复执行 | `286-292` | 加 `_CLEANED` 幂等守卫 |
| L7 | Python：`import os` 置于文件**中部**（`19`）；正则爬 HTML 脆弱、无重试、失败即 `sys.exit(1)` 让 CI 硬失败 | `fetch_nf_ix_map.py` | import 置顶；爬取加重试 / 容错；考虑数据源稳定性 |
| L8 | `ping6` 已过时，部分系统缺失 → IPv6 延迟恒为 `--` | `1662, 1694` | 改用 `ping -6` |
| L9 | **隐私**：将服务器真实 IP 发往多家第三方及个人域名 `bgp-view.jam114514.me` | `986` 等 | 工具性质可接受，但应在文档/输出中**明确告知**用户 |
| L10 | README 漂移：IP 质量数据来源描述与代码不完全一致；`README.md` 大小写与实际 `readme.md` 不符 | `readme.md` | 对齐文档与实现 |
| L11 | `apt-get autoremove -y` 可能移除**超出脚本安装范围**的孤立依赖 | `255` | 仅移除 `CLEANUP_PKGS`，谨慎使用 autoremove；或文档提示 |

**L3 复制粘贴明细**：
- `collect_network_info` 的 v4 / v6 两段近 50 行**近乎逐字相同**（`766-853` vs `878-955`）→ 抽成一个接受 `ipflag` 的函数。
- `run_trace_test` 与 `run_forward_trace_test` 的 jq 解析块约 35 行**逐字重复**（`2849-2882` vs `3064-3084`）。
- `collect_network_info` / `collect_ip_quality` 内**重新实现了 retry 循环**，却没复用已有的 `retry_download`。
- 各工具下载块结构高度重复 → 抽 `download_tool(name, url, ...)` 帮助函数（与 S1 的校验逻辑合并实现，一举两得）。

**其他低优先正确性点**：
- `run_cpu_test`：`multi=$(calc "$score_nt / $score_1t")`，当 `score_1t` 为空 / 0 时 awk 除零或语法错（`1269`）。
- CI（`fetch_nf_ix_map.yml`）总体可用：`commit` 后 `git pull --rebase` 再 `push`，靠 `concurrency` 串行化；push 的是 `.txt` 而 path 过滤只含 `yml/py`，**不会自触发死循环**。唯一小风险：若 `main` 开启分支保护，bot 直推会失败。

---

## 4. 优先级修复计划

### P0 — 立即（安全，必须先做）
1. **S3**：轮换并移除硬编码 NextTrace JWT token（含 git 历史）。
2. **S1**：为所有下载引入"版本固定 + sha256 校验"。建议先实现一个 `download_and_verify` 帮助函数，再逐个接入 nexttrace / yt-dlp / cf-speed / inetspeed / geekbench6 / check.sh。把 `file.lowendaff.com` 降为备用源、与官方源共用同一份哈希。
3. **H1**：修复 `--fix-dns` 的符号链接 / systemd-resolved 兼容与恢复健壮性；在彻底修好前，给该选项加显著风险告警。

### P1 — 近期（健壮性，低风险高收益）
4. **H3**：`TMP_DIR` 改 `mktemp -d`。
5. **L1**：删除 `linux_bench.old.sh`。
6. **H4**：所有整数比较前做数字校验。
7. **H5**：锁定上游 `check.sh` 版本；解析失败显式告警。
8. **L5 / L6 / L8**：补 `local`、cleanup 幂等守卫、`ping6`→`ping -6`。
9. **H2**：引入 `set -o pipefail` + 关键路径检查（**需配合引号审计与完整回归测试**，故列 P1 而非 P0）。

### P2 — 路线图（可维护性，较大改动）
10. **L2**：模块化拆分为 `lib/` 多文件。
11. **L3**：消除复制粘贴（v4/v6、jq 解析块、下载器、retry）。
12. **L4**：`normalize_isp_name` 改查表实现。
13. **L7 / L9 / L10 / L11**：Python 清理、隐私告知、文档对齐、autoremove 收敛。

---

## 5. 一句话结论

**先把"下载即 root 执行且零校验"（S1）和硬编码凭据（S3）堵上——这是把别人服务器交给你跑脚本时最不可接受的两点；其余健壮性与可维护性问题可按 P1/P2 渐进推进。**
