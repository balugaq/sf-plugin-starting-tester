# AGENTS.md

面向在本仓库工作的 AI 代理（与人类协作者）的项目指南。动手前先读完本文件。

## 项目是什么

基于 GitHub Actions 的 Slimefun 附属启动兼容性测试框架：从鬼斩资源站
（resources.guizhanss.com）批量下载插件及其依赖，在指定 MC 版本的 Paper
服务端上单次开服批量测试能否正常启用，产出 HTML 报告与机器可读结果。
前端控制台部署在 GitHub Pages。

## 目录结构

- `.github/workflows/test-compatibility.yml` — 主测试 workflow（手动 dispatch）
- `.github/workflows/deploy-pages.yml` — push 到 master 改动 `pages/**` 时部署 Pages
- `scripts/resolve-plugin.sh` — 资源站解析/下载：批量 slug、依赖自动解析、名字映射缓存
- `scripts/run-server.sh` — 下载 Paper、开服、按日志逐插件判定、产出 result-*.json
- `scripts/build-report.py` — 汇总 result-*.json → report.html + results.json
- `pages/index.html` — 控制台页面（内联 JS/CSS）
- `pages/i18n.js` — 多语言文本字典（zh-CN / en，各 ~88 key）
- `pages/conflicts.json` — 插件冲突规则（contains/included/reason）
- `extra-plugins/` — 用户自备 jar（依赖的依赖等特殊场景）

## 硬性约定（改代码前必读）

1. **两处 `_site` 组装必须同步**：`deploy-pages.yml` 与
   `test-compatibility.yml` 的 report job 各自组装 Pages 站点。凡新增
   `pages/` 下的资源文件（html/js/json），两处都要补 `cp`，否则线上 404
   导致整页白屏（曾踩坑：i18n.js 忘拷 → 全空白）。
2. **i18n 双语字典同步**：`pages/i18n.js` 中 zh-CN 与 en 的 key 必须一一
   对应；新增界面文本时两份都加，用 node 校验（见下）。
3. **脚本一律 `set -euo pipefail`**：注意退出码穿透（unzip 找不到文件返回
   11、curl -sf 吞 404 成空串），易错处必须显式容错。
4. **jq 坑**：资源站目录是逐行 JSONL，过滤必须 `jq -s`（slurp）成数组；
   产出拼接 JSON 用 `jq -nc` / `jq -s -c` 紧凑单行，多行 pretty 拼数组会
   因缺逗号非法。
5. **jar 文件名可能带空格**：遍历用 `while IFS= read -r`，不要用词拆分。
6. **新下载判定用 mtime**：依赖会同名覆盖，靠 `touch marker` + `-nt` 判
   「本次新下载」；任何引入缓存/复用文件的改动都要保证 cp 出来的文件
   mtime 晚于 marker。
7. **缓存策略**：Actions cache 用静态 key，条目级失效交给 GitHub（7 天无
   访问自动驱逐）；文件级过期由脚本内 `find -mtime` 清理（资源站 7 天、
   服务端 14 天）。改 key 时保留 `-v1` 风格。
8. **JDK 分级**：MC ≥26 → Java 25，≥1.20.5 → 21，更早 → 17（temurin）。
9. **依赖解析零硬编码**：不做别名映射（如 Slimefun→Slimefun4 的写死分支
   禁止），一律全站目录候选 + plugin.yml 实名验证 + `.name_map.json` 持久
   缓存。
10. **前端文本全部走 i18n**：静态文本用 `data-i18n` / `data-i18n-html` /
    `data-i18n-ph`，动态字符串用 `t(key, vars)`；禁止在 HTML/JS 里写死
    面向用户的文案。`t()`/`applyI18n()` 内联在 index.html（字典缺失时兜
    底显示 key，不允许白屏）。
11. **用户输入一律转义**：插进 innerHTML 的内容过 `esc()`/`hi()`，防注入。
12. **注释与提交信息用中文**；引号在代码里只用 ASCII 直引号。

## 验证手段（提交前）

- Shell：`bash -n scripts/*.sh`，复杂逻辑用沙箱目录模拟跑通再落库
- Python：`python -m py_compile scripts/build-report.py`
- i18n：node 桩加载 `i18n.js`，校验中英 key 对齐、页面引用无缺 key
- workflow：YAML 结构肉眼复核 + grep 确认改动落地；表达式函数表只有
  format/join/contains/toJSON/fromJSON/hashFiles，**没有 replace/split**
  （字符串处理挪到 shell + jq 里做，setup job 算好经 outputs 传矩阵）
- 页面视觉由维护者人工确认，代理不做浏览器截图验证

## 发布链路

1. push 到 `master` 且改动 `pages/**` → `deploy-pages.yml` 自动部署控制台
2. 测试运行完成后 report job 会用「控制台 + 最新报告 + results.json」覆盖
   部署（concurrency group `pages`，排队不并发）
3. dependabot 每周检查 github-actions 依赖，minor/patch 合并成一个 PR

## 其他

- 主分支是 `master`（不是 main，workflow 与控制台默认分支均按此）
- 仓库有 MIT LICENSE；fork 仓库的 Actions 可能被 GitHub 自动关闭，重新
  开启即可（README 有说明）
- GUIZHAN_TOKEN 是可选 secret，仅用于资源站 API 提额
