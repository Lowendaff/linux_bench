# Linux Bench (Lowendaff Edition)

**Linux Bench** 是一个综合性的 Linux 服务器性能测试与网络质量检测脚本。它集成了业界主流的测试工具，旨在为用户提供一键式的硬件性能评估、网络连通性测试及流媒体服务解锁检测。

本项目特别针对服务器维护者设计，默认运行全部测试、可用 `--skip-xxx` 按需跳过，并包含自动维护机制以确保测试数据的准确性。

## 📚 项目概述

* **核心功能**：一键检测 CPU/磁盘性能、网络带宽、路由追踪、IP 质量（欺诈/原生检测）及流媒体解锁情况。
* **解决问题**：简化繁琐的服务器测试流程，提供可视化、标准化的测试报告。
* **目标用户**：Linux 服务器管理员、VPS 爱好者、运维工程师。

## 🛠 技术栈

本项目使用以下技术构建：

* **核心语言**：Bash Shell (用于主控逻辑与交互)
* **辅助工具**：Python 3.12 (用于数据抓取与处理)
* **CI/CD**：GitHub Actions (用于自动化定时任务)
* **依赖组件**（脚本自动管理）：
* **系统工具**：`curl`, `jq`, `tar`, `xz-utils`
* **性能测试**：`sysbench` (CPU), `fio` (磁盘), `geekbench6` (基准跑分)
* **网络工具**：`iperf3` (带宽), `nexttrace` (路由追踪), `cloudflare-speed-cli` (Cloudflare 测速), `iNetSpeed-CLI` (Apple CDN 测速), `yt-dlp` (动态 YouTube CDN 检测)



## 📥 安装与部署

### 环境要求

* **操作系统**：Linux (仅支持 Debian 或 Ubuntu 发行版)
* **权限**：需要 `root` 权限或 `sudo` 权限
* **网络**：需具备正常的互联网连接以下载依赖工具

### 快速安装

您可以通过以下命令直接下载并运行脚本

```bash
bash <(curl -L -s bench.lowendaff.com)
```

### 部署自动更新

如果您 Fork 了本项目，可以启用 GitHub Actions 以自动更新 Netflix IX 映射数据：

1. 确保 `.github/workflows/fetch_nf_ix_map.yml` 存在。
2. Actions 会在每周一 UTC 00:00 (北京时间 08:00) 自动运行。
3. 也可以在 GitHub 页面手动触发 `workflow_dispatch`。

## 🚀 快速上手

脚本支持多种参数以适应不同测试场景：

### 1. 综合测试（默认执行全部测试）

```bash
bash <(curl -L -s bench.lowendaff.com)
```

启动后将显示 ASCII 欢迎界面，并提示相关说明。

> 💡 **提示**: 默认测试中的 Geekbench (GB) 跑分环节耗时较长。如果需要执行除 GB 外的完整测试，可以使用如下命令：
> ```bash
> bash <(curl -L -s bench.lowendaff.com) --skip-gb
> ```

### 2. 按需跳过功能（`--skip-xxx`）

**默认运行全部测试**。用 `--skip-xxx` 关闭单项功能，可叠加、顺序无关。

| 开关 | 关闭的功能 |
| :--- | :--- |
| `--skip-sysinfo` | 系统信息 |
| `--skip-netinfo` | 网络信息（会**级联**关闭依赖它的网络项） |
| `--skip-bgp` | BGP 透视 |
| `--skip-ip-quality` | IP 质量检测 |
| `--skip-service` | 服务解锁（流媒体 / AIGC） |
| `--skip-cpu` | CPU 测试（sysbench） |
| `--skip-gb` | Geekbench 6 |
| `--skip-disk` | 磁盘测试（fio） |
| `--skip-iperf` | iperf3 带宽测试 |
| `--skip-cloudflare` | Cloudflare CDN 测速 |
| `--skip-apple` | Apple CDN 测速 |
| `--skip-trace` | 回程路由追踪 |
| `--skip-forward` | 去程路由追踪 |
| `--skip-hardware` | 全部硬件测试（= cpu + gb + disk） |
| `--skip-speedtest` | 全部测速（= iperf + cloudflare + apple） |

示例：

```bash
sudo ./linux_bench.sh                                      # 全部
sudo ./linux_bench.sh --skip-gb                            # 全部但跳过最慢的 Geekbench
sudo ./linux_bench.sh --skip-speedtest --skip-trace --skip-forward   # 不测速、不追踪
sudo ./linux_bench.sh --skip-netinfo                      # 关网络信息（级联），只剩硬件 + cf/apple
```

### 3. 修饰选项

* **强制 IP 版本** (`-4`, `-6`)
  ```bash
  sudo ./linux_bench.sh -4              # 仅 IPv4
  sudo ./linux_bench.sh -6 --skip-gb   # 仅 IPv6 + 跳过 GB
  ```

* **修复 DNS** (`--fix-dns`)
  * 测试期间临时覆盖系统 DNS（解决部分节点网络查询超时；结束时自动恢复）
  ```bash
  sudo ./linux_bench.sh --fix-dns
  ```

* **数据输出格式** (`--raw`, `--normalize`)
  * `--raw`：原始未标准化数据（默认）
  * `--normalize`：标准化处理（地名去后缀、运营商名称统一）
  ```bash
  sudo ./linux_bench.sh --normalize
  ```

* **帮助** (`-h`, `--help`)
  ```bash
  sudo ./linux_bench.sh --help
  ```

## 📂 核心功能与目录结构

```text
.
├── .github/
│   └── workflows/
│       └── fetch_nf_ix_map.yml   # CI配置：定期抓取 Netflix IX 数据
├── utils/
│   ├── fetch_nf_ix_map.py        # Python脚本：爬取 PeeringDB 解析 IX IP
│   ├── nf_ix_map.txt             # 数据文件：Netflix IX 的 IP 映射
│   ├── trace_targets.txt         # 数据文件：回程路由追踪目标列表
│   └── forward_sources.txt       # 数据文件：去程路由追踪源列表
├── linux_bench.sh                # 主程序：整合各项测试逻辑
└── README.md                     # 说明文档

```

### 关键模块说明

1. **系统检查 (`linux_bench.sh`)**：自动检测 OS 版本、虚拟化类型、CPU/内存/磁盘信息。
2. **IP 质量检测**：调用 `ipapi.is`，`ipapi.co` 和 `ippure.com` API，分析 IP 的欺诈分、ISP 类型及是否为原生 IP。
3. **路由追踪**：集成 `NextTrace`，支持回程（从服务器到目标）和去程（从全球到服务器）双向追踪，自动识别并标注 Netflix 的 IX 节点。
4. **数据维护 (`utils/`)**：
   * `nf_ix_map.txt` - Netflix 交换中心 IP 数据（由 GitHub Actions 自动更新）
   * `trace_targets.txt` - 回程路由追踪目标列表（支持远程更新）
   * `forward_sources.txt` - 去程路由追踪源列表（支持远程更新）

## 🤝 贡献指南

欢迎提交 Pull Request 或 Issue！

* **代码规范**：Shell 脚本请遵循 Bash 最佳实践，Python 脚本建议使用 Python 3.12+ 特性。
* **提交方式**：
1. Fork 本仓库。
2. 创建特性分支 (`git checkout -b feature/NewFeature`)。
3. 提交更改。
4. 推送至分支并提交 PR。


* **数据更新**：如果是更新 `nf_ix_map.txt`，建议通过 GitHub Actions 自动触发，而非手动修改。

## 📜 许可证

本项目使用 **GNU GPL v3.0** 许可证。


## 🙏 致谢/参考

**特别感谢**：**Google Antigravity**，没有它就没有这个脚本。

本项目基于或引用了以下优秀的开源项目与服务：


* **[NextTrace](https://github.com/nxtrace/NTrace-core)** : NextTrace, an open source visual route tracking CLI tool
* **[RegionRestrictionCheck](https://github.com/1-stream/RegionRestrictionCheck)** : A bash script to check if your VPS's IP is available for various OTT platforms
* **[Geekbench 6 - Cross-Platform Benchmark](https://www.geekbench.com/)**: Geekbench 6 is a cross-platform benchmark that measures your system's performance with the press of a button
* **[sysbench](https://github.com/akopytov/sysbench)** : Scriptable database and system performance benchmark
* **[cloudflare-speed-cli](https://github.com/kavehtehrani/cloudflare-speed-cli)** : CLI for internet speed test via cloudflare
* **[iNetSpeed-CLI](https://github.com/tsosunchia/iNetSpeed-CLI)** : Apple CDN speed test CLI tool
* **[yt-dlp](https://github.com/yt-dlp/yt-dlp)** : A feature-rich command-line audio/video downloader
* **IP 数据来源**: ipapi.co, ipapi.is, ippure.com, PeeringDB

本项目感谢以下商家提供服务
* **[Misaka Network, Inc.](https://www.misaka.io/)**
* **[YOUTHIDC](https://yun.youthidc.com/)**

