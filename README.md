<div align="center">

# sf-plugin-starting-tester

**快速测试粘液附属在特定版本上能否运行**

[![CI 测试](https://github.com/balugaq/sf-plugin-starting-tester/actions/workflows/test-compatibility.yml/badge.svg)](https://github.com/balugaq/sf-plugin-starting-tester/actions/workflows/test-compatibility.yml)
[![Stars](https://img.shields.io/github/stars/balugaq/sf-plugin-starting-tester?style=flat&logo=github)](https://github.com/balugaq/sf-plugin-starting-tester/stargazers)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

</div>

---

## 项目背景

### 问题

Minecraft 版本迭代快且碎片化，而粘液（Slimefun）附属的更新参差不齐——很多附属的发布说明停留在很老的版本，标注的「支持版本」早已过时，**没有任何精确数据能判断一个附属到底能在哪些 MC 版本上跑起来**。盲装轻则报错刷屏，重则开服崩溃。

### 目的

旨在让人**快速验证某个附属能否在目标服务器上运行**：批量构建出各个粘液附属实际支持的 MC 版本清单，也可以用于个人自行做简单测试——不需要自己开服、不需要装环境，点一下就行。

### 原理

使用 **GitHub Actions** 完成「下载 → 开服 → 判定 → 报告」全流程：

1. 通过[鬼斩资源站 API](https://resources.guizhanss.com)下载插件 jar（含 sha256 校验），自动解析 `plugin.yml` 安装硬依赖（depend），并按名字从全站目录动态解析依赖的真实身份（无任何硬编码映射）；
2. 按 MC 版本自动选择对应 JDK，从 [fill.papermc.io](https://fill.papermc.io) 下载 Paper（另支持 purpur / folia）并启动服务端；
3. 以日志出现 `Done (` 且无 `Error occurred while enabling <插件>` 判定启动成功，失败时提取日志末尾报错段；
4. 汇总生成单页 HTML 报告（每个插件 ✔ / ✘ + 报错原文），上传为 artifact 并部署到 GitHub Pages。

### 支持能力

- **单端多版本并行测试**：填多个 MC 版本，每个版本一次开服，矩阵并行跑完；
- **多附属同服测试**：一次开服同时安装上百个附属，只测启动兼容性；
- **结果可下载**：每次运行结束在 Artifacts 下的 `compatibility-report` 中提供完整报告。

## 如何使用

1. **Fork 本仓库**，进入你 fork 后的项目主页，依次打开 **Settings → Pages**，将 Source 设置为 **GitHub Actions**；
2. 等待 **GitHub Pages 自动部署**完成，打开你 fork 仓库的 Pages 地址（即测试控制台）；
3. 创建你自己的 **GitHub Token**（[fine-grained PAT](https://github.com/settings/personal-access-tokens/new)），仅勾选本仓库的 **Actions: Read and write** 权限，用于控制台自动触发与轮询 workflow；
4. 创建 **Guizhan Token**（[资源站 → 设置 → Tokens](https://resources.guizhanss.com/settings/tokens)），无需任何权限，仅用于提高每小时的 API 请求额度；
5. 在控制台中填入 **GitHub Token、Guizhan Token、你自己的仓库（owner/repo）及分支**；
6. 勾选要测试的插件，选择**服务端平台**与 **MC 版本**；
7. 点击运行。等待运行完成后，可在你仓库的 **GitHub Actions** 中查看 workflow 运行结果；测试结果在 **Artifacts** 下的 **`compatibility-report`** 中。

> 补充：依赖的依赖等特殊 jar 可提交到 fork 仓库的 `extra-plugins/` 目录（会原样拷入服务端 `plugins/`）；软依赖（softdepend）默认不装，`GuizhanLibPlugin` 例外——它是必装前置，会自动安装。Token 只存浏览器 localStorage，不经过任何第三方。
>
> **提示**：你可能会遇到 GitHub Actions 被自动关闭的情况，这是 GitHub 对 fork 仓库的正常扫描行为，只需到仓库的 **Actions** 页面重新开启即可。

## 开源协议

[MIT](LICENSE)
