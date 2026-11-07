# sf-plugin-starting-tester

在 GitHub Actions 上自动测试 Minecraft 插件能否正常启动——fork 这个仓库，填入鬼斩资源站的项目 slug 和 MC 版本，跑完得到一份 HTML 报告（每个版本 ✔ 启动成功 / ✘ 启动失败 + 具体报错），全程不需要自己开服。

## 这是什么

工作流做四件事：

1. **下载插件**：通过[鬼斩资源站 API](https://resources.guizhanss.com/api/v1/projects) 按 slug + 版本下载插件 jar（含 sha256 校验），并自动解析 `plugin.yml` 的 `depend` 硬依赖、一并下载（深度 1 层）。
2. **开服测试**：按 MC 版本自动选择 JDK（1.20.5+ → Java 21，更早 → Java 17），从 [fill.papermc.io](https://fill.papermc.io) 下载 Paper（支持 purpur/folia），启动服务端。
3. **判定成败**：日志出现 `Done (` 且没有 `Error occurred while enabling <插件>` 视为通过；超时或崩溃则提取日志末尾报错段。
4. **汇总报告**：所有版本的 JSON 结果合并生成单页 HTML（成功绿 / 失败红 + 报错原文），上传为 artifact，可选发布到 GitHub Pages。

## 如何使用

1. **Fork 本仓库**，并在 fork 仓库的 **Actions 标签页点一下启用**（fork 默认禁用 Actions）。
2. **Actions → Plugin Compatibility Test → Run workflow**，填参数：

   | 参数 | 说明 | 示例 |
   |---|---|---|
   | plugin_slug | 资源站项目 slug | `infinity-machines` |
   | plugin_version | 版本号，留空取最新 release | `1.2.0` |
   | minecraft_versions | 逗号分隔的 MC 版本 | `1.21.4,1.20.6,1.20.4` |
   | platform | 服务端平台 | `paper` |
   | start_timeout | 单次开服超时秒数 | `600` |
   | publish_pages | 勾选则把报告发布到 Pages | `false` |

3. 跑完后在本次运行页面下载 **compatibility-report** artifact，解压打开 `report.html`；或勾选 publish_pages 后到仓库 Pages 设置开启托管，直接用链接看。
4. （可选）在仓库 Settings → Secrets 添加 `GUIZHAN_TOKEN`（在资源站 settings/tokens 生成），可获得更高的 API 额度；不填也能测公开插件。

注意：`workflow_dispatch` 只对**默认分支**上的 workflow 生效，改动 workflow 文件后记得合到默认分支。

## 判定口径

「启动成功」仅覆盖启动阶段：Bukkit 加载 plugin.yml → 硬依赖满足 → `onEnable()` 跑完无异常。**不覆盖**运行期报错、玩家交互、性能问题，报告结果请勿当作插件质量背书。

## 开发中已知的问题与风险

- **依赖解析深度只有 1 层**：依赖的依赖不会自动装；`softdepend` 不下载，缺前置可能造成假失败。资源站搜索按名称精确匹配，改名插件可能搜不到。
- **Slimefun4 不在资源站**：`depend: [Slimefun]` 目前被跳过，需要时另行接入其 Jenkins/构建源。
- **API 版本前缀是坑**：文档只写相对路径，真实前缀是 `/api/v1`（文档首页给的 `/api/` 探测地址会返回 Route not found）。脚本已内置正确前缀，但上游文档变更时这里最先坏。
- **限流**：匿名调资源站 API 有速率限制，MC 版本矩阵大时建议配 `GUIZHAN_TOKEN`。
- **Paper 下载依赖 fill.papermc.io v3 API**：`downloads["server:default"].url` 字段名是上游约定，变更需同步改 `scripts/run-server.sh`。
- **假阴性可能**：插件 onEnable 抛异常但服务端仍能 `Done (`，判定逻辑已针对性检测 `Error occurred while enabling`；若插件用非常规方式报错可能漏检，建议结合完整 console 日志人工复核。

## 文件结构

```
.github/workflows/test-compatibility.yml   # 入口工作流（dispatch → 矩阵测试 → 报告）
scripts/resolve-plugin.sh                  # 资源站下载 + plugin.yml 依赖解析
scripts/run-server.sh                      # JDK 选择、Paper 下载、开服与成败判定
scripts/build-report.py                    # result-*.json → report.html
```

## License

见 [LICENSE](LICENSE)。
