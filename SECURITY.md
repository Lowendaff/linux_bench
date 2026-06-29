# 安全说明

## 凭据
- 历史版本曾在 `linux_bench.sh` 中硬编码 NextTrace API token（已于本次加固移除）。
  该 token 必须被视为**已泄露**：请在 NextTrace 侧**轮换/吊销**，并用
  `git filter-repo --replace-text` 或 BFG 从 git 历史中清除。
- 现在 NextTrace token 仅通过环境变量 `NEXTTRACE_TOKEN` 提供（可选）。

## 下载完整性
- `download_and_verify`（sha256 校验）已实现，但**尚未接入**实际下载调用点；
  当前所有外部下载仍走 `retry_download`，**不做校验**。
- `utils/checksums.txt` 也尚未创建。
- 校验和接线及 `utils/checksums.txt` 维护已列为延后任务（T5），完成前本控制项不视为生效。
