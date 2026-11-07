# sf-plugin-starting-tester

在 GitHub Actions 上自动测试 Minecraft 插件能否正常启动——fork 这个仓库，填入鬼斩资源站的项目 slug 和 MC 版本，跑完得到一份 HTML 报告（每个版本 ✔ 启动成功 / ✘ 启动失败 + 具体报错），全程不需要自己开服。

## 这是什么

工作流做四件事：

1. **下载插件**：通过[鬼斩资源站 API](https://resources.guizhanss.com/api/v1/projects) 按 slug + 版本下载插件 jar（含 sha256 校验），自动安装 `plugin.yml` 声明的硬依赖（depend，含 Slimefun4）与勾选的软依赖（softdepend）。
2. **开服测试**：按 MC 版本自动选择 JDK（1.20.5+ → Java 21，更早 → Java 17），从 [fill.papermc.io](https://fill.papermc.io) 下载 Paper（支持 purpur/folia），启动服务端。
3. **判定成败**：日志出现 `Done (` 且没有 `Error occurred while enabling <插件>` 视为通过；超时或崩溃则提取日志末尾报错段。
4. **汇总报告**：所有版本的 JSON 结果合并生成单页 HTML（成功绿 / 失败红 + 报错原文），上传为 artifact，可选发布到 GitHub Pages。

## 如何使用

有两种触发方式，效果相同：

### 方式一：网页控制台（推荐）

Fork 后开启 Pages（Settings → Pages → Source 选 **GitHub Actions**），访问 `https://<你的用户名>.github.io/<仓库名>/` 即是测试控制台：

1. 填一次 fine-grained PAT（只勾选本仓库的 **Actions: Read and write**，存浏览器 localStorage，不经过第三方）；
2. 填插件 slug、MC 版本、平台等，点 **触发测试**；
3. 页面自动轮询并显示每个 MC 版本的 ✔/✘ 结果，日志直达 GitHub run 页；每次测试的 HTML 报告也会部署在 Pages 的 `report.html`。

### 方式二：手动触发 workflow

   | 参数 | 说明 | 示例 |
   |---|---|---|
   | plugin_slug | 资源站项目 slug | `infinity-machines` |
   | plugin_version | 版本号，留空取最新 release | `1.2.0` |
   | softdepend_plugins | 额外安装的 softdepend 插件名，逗号分隔（GuizhanLibPlugin 始终自动安装） | `eco,PlaceholderAPI` |
   | extra_jars | 自备 jar 下载直链，逗号分隔 | `https://.../xxx.jar` |
   | minecraft_versions | 逗号分隔的 MC 版本 | `1.21.4,1.20.6,1.20.4` |
   | platform | 服务端平台 | `paper` |
   | start_timeout | 单次开服超时秒数 | `600` |

**补装依赖的依赖等特殊 jar 有两个途径**：把 jar 提交到 fork 仓库的 `extra-plugins/` 目录（会原样拷进 `plugins/`），或在 `extra_jars` 输入里给下载直链。`softdepend` 默认不装（避免无关前置干扰判定），`GuizhanLibPlugin` 例外——它是必装前置，勾不勾都会自动安装。

3. 跑完后每个 MC 版本的 ✔/✘ 结论显示在控制台页面（或 run 页面），HTML 报告自动部署到 Pages 的 `report.html`，完整 console 日志在 run 页或 `compatibility-report` artifact 里。
4. （可选）在仓库 Settings → Secrets 添加 `GUIZHAN_TOKEN`（在资源站 settings/tokens 生成），可获得更高的 API 额度；不填也能测公开插件。

注意：`workflow_dispatch` 只对**默认分支**上的 workflow 生效，改动 workflow 文件后记得合到默认分支。

## 判定口径

「启动成功」仅覆盖启动阶段：Bukkit 加载 plugin.yml → 硬依赖满足 → `onEnable()` 跑完无异常。**不覆盖**运行期报错、玩家交互、性能问题，报告结果请勿当作插件质量背书。

## 开发中已知的问题与风险

- **依赖解析深度只有 1 层**：依赖的依赖不自动装，用户通过 `extra-plugins/` 目录或 `extra_jars` 直链自行补充；资源站搜索按名称精确匹配，改名插件可能搜不到（`Slimefun` → `Slimefun4` 已内置别名映射）。
- **API 版本前缀是坑**：文档只写相对路径，真实前缀是 `/api/v1`（文档首页给的 `/api/` 探测地址会返回 Route not found）。脚本已内置正确前缀，但上游文档变更时这里最先坏。
- **限流**：匿名调资源站 API 有速率限制，MC 版本矩阵大时建议配 `GUIZHAN_TOKEN`。
- **Paper 下载依赖 fill.papermc.io v3 API**：`downloads["server:default"].url` 字段名是上游约定，变更需同步改 `scripts/run-server.sh`。
- **假阴性可能**：插件 onEnable 抛异常但服务端仍能 `Done (`，判定逻辑已针对性检测 `Error occurred while enabling`；若插件用非常规方式报错可能漏检，建议结合完整 console 日志人工复核。

## 文件结构

```
.github/workflows/test-compatibility.yml   # 入口工作流（dispatch → 矩阵测试 → 报告 + Pages）
pages/index.html                           # 网页控制台（触发测试、展示各版本结果）
scripts/resolve-plugin.sh                  # 资源站下载 + depend/softdepend 依赖解析
scripts/run-server.sh                      # JDK 选择、Paper 下载、开服与成败判定
scripts/build-report.py                    # result-*.json → report.html
extra-plugins/                             # 用户自备 jar（提交进来即自动装）
```

## License

见 [LICENSE](LICENSE)。
