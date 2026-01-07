# Linux Bench (Lowendaff Edition)

**Linux Bench** 是一个综合性的 Linux 服务器性能测试与网络质量检测脚本。它集成了业界主流的测试工具，旨在为用户提供一键式的硬件性能评估、网络连通性测试及流媒体服务解锁检测。

本项目特别针对服务器维护者设计，支持多种测试模式，并包含自动维护机制以确保测试数据的准确性。

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
* **系统工具**：`curl`, `jq`
* **性能测试**：`sysbench` (CPU), `fio` (磁盘), `geekbench6` (基准跑分)
* **网络工具**：`iperf3` (带宽), `nexttrace` (路由追踪), `cloudflare-speed-cli` (Cloudflare测速), `yt-dlp` (动态YouTube CDN检测)



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

### 2. 指定模式运行

跳过交互菜单，直接运行特定模块：

* **综合网络测试** (`-n`, `--network`)
  * 包含: 基础网络信息、BGP透视、IP质量检测、服务解锁、Speedtest测速
  ```bash
  sudo ./linux_bench.sh -n
  ```

* **硬件性能测试** (`-h`, `--hardware`)
  * 包含: CPU Benchmark、内存、磁盘IO
  ```bash
  sudo ./linux_bench.sh -h
  ```

* **路由追踪** (`-t`, `--nexttrace`)
  * 包含: 回程路由追踪、公共服务/CDN节点追踪
  ```bash
  sudo ./linux_bench.sh -t
  ```

* **公共服务** (`-p`, `--public`)
  * 包含: 仅对 Google/Cloudflare DNS 等公共节点进行路由追踪
  ```bash
  sudo ./linux_bench.sh -p
  ```

* **IP 质量检测** (`-i`, `--ip-quality`)
  * 包含: IP欺诈值、风险评分、流媒体解锁详情
  ```bash
  sudo ./linux_bench.sh -i
  ```

* **服务解锁** (`-s`, `--service`)
  * 包含: Netflix、Disney+ 等流媒体及 AIGC/GPT 解锁检测
  ```bash
  sudo ./linux_bench.sh -s
  ```

* **强制 IP 版本** (`-4`, `-6`)
  * 强制仅使用 IPv4 或 IPv6 协议
  ```bash
  sudo ./linux_bench.sh -n -4  # 仅 IPv4 网络测试
  sudo ./linux_bench.sh -s -6  # 仅 IPv6 解锁测试
  ```

## 📂 核心功能与目录结构

```text
.
├── .github/
│   └── workflows/
│       └── fetch_nf_ix_map.yml   # CI配置：定期抓取 Netflix IX 数据
├── utils/
│   ├── fetch_nf_ix_map.py        # Python脚本：爬取 PeeringDB 解析 IX IP
│   └── nf_ix_map.txt             # 数据文件：存储 IP 与 IX 的映射关系
├── linux_bench.sh                # 主程序：整合各项测试逻辑
└── README.md                     # 说明文档

```

### 关键模块说明

1. **系统检查 (`linux_bench.sh`)**：自动检测 OS 版本、虚拟化类型、CPU/内存/磁盘信息。
2. **IP 质量检测**：调用 `ipapi.is`，`ipapi.co` 和 `ippure.com` API，分析 IP 的欺诈分、ISP 类型及是否为原生 IP。
3. **路由追踪**：集成 `NextTrace`，自动识别并标注 Netflix 的 IX 节点（依赖 `utils/nf_ix_map.txt` 数据）。
4. **数据维护 (`utils/`)**：`fetch_nf_ix_map.py` 脚本负责从 PeeringDB 抓取 Netflix 的交换中心 IP 数据，确保路由追踪的准确性。

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

本项目基于或引用了以下优秀的开源项目与服务：


* **[NextTrace](https://github.com/nxtrace/NTrace-core)** : NextTrace, an open source visual route tracking CLI tool
* **[RegionRestrictionCheck](https://github.com/1-stream/RegionRestrictionCheck)** : A bash script to check if your VPS's IP is available for various OTT platforms
* **[Geekbench 6 - Cross-Platform Benchmark](https://www.geekbench.com/)**: Geekbench 6 is a cross-platform benchmark that measures your system's performance with the press of a button
* **[sysbench](https://github.com/akopytov/sysbench)** : Scriptable database and system performance benchmark
* **[cloudflare-speed-cli](https://github.com/kavehtehrani/cloudflare-speed-cli)** : CLI for internet speed test via cloudflare
* **[yt-dlp](https://github.com/yt-dlp/yt-dlp)** : A feature-rich command-line audio/video downloader
* **IP 数据来源**: ipapi.co, ipapi.is, ippure.com, PeeringDB

本项目感谢以下商家提供服务
* **[Misaka Network, Inc.](https://www.misaka.io/)**
* **[YOUTHIDC](https://yun.youthidc.com/)**

