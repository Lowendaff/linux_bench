# 安全说明

## 凭据
- 历史版本曾在 `linux_bench.sh` 中硬编码 NextTrace API token（已于本次加固移除）。
  该 token 必须被视为**已泄露**：请在 NextTrace 侧**轮换/吊销**，并用
  `git filter-repo --replace-text` 或 BFG 从 git 历史中清除。
- 现在 NextTrace token 仅通过环境变量 `NEXTTRACE_TOKEN` 提供（可选）。

## 下载完整性
- 所有外部二进制/脚本下载均经 `download_and_verify`，对照 `utils/checksums.txt`
  做 sha256 校验。新增/升级工具时需同步更新该文件（见 utils/checksums.txt 顶部说明）。
