#!/usr/bin/env python3
"""汇总所有 result-*.json，生成单页 HTML 测试报告 report.html。"""
import glob
import html
import json
import os

results = []
for path in sorted(glob.glob("results/result-*.json")):
    with open(path, encoding="utf-8") as f:
        results.append(json.load(f))

if not results:
    results.append({"slug": "?", "version": "?", "mc_version": "?",
                    "platform": "?", "status": "failure",
                    "error_excerpt": "未找到任何结果文件", "java": "?"})

total = len(results)
passed = sum(1 for r in results if r.get("status") == "success")
slug = next((r.get("slug") for r in results if r.get("slug")), "?")
version = next((r.get("version") for r in results if r.get("version")), "latest")

rows = []
for r in results:
    ok = r.get("status") == "success"
    color, badge = ("#0a7d32", "✔ 启动成功") if ok else ("#c62828", "✘ 启动失败")
    excerpt = r.get("error_excerpt") or ""
    detail = f'<pre class="err">{html.escape(excerpt)}</pre>' if excerpt else ""
    rows.append(f"""
    <div class="card {'pass' if ok else 'fail'}">
      <div class="head">
        <span class="badge" style="background:{color}">{badge}</span>
        <span class="mcver">MC {html.escape(str(r.get('mc_version', '?')))}</span>
        <span class="meta">{html.escape(str(r.get('platform', '?')))} · Java {html.escape(str(r.get('java', '?')))}</span>
      </div>
      {detail}
    </div>""")

out = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>兼容性测试报告 - {html.escape(slug)}</title>
<style>
  body {{ font-family: system-ui, sans-serif; max-width: 860px; margin: 2rem auto; padding: 0 1rem; background:#11151c; color:#e6e6e6; }}
  h1 {{ font-size: 1.4rem; }}
  .summary {{ margin-bottom: 1.5rem; color:#aaa; }}
  .card {{ border: 1px solid #333; border-radius: 8px; margin-bottom: 1rem; overflow: hidden; }}
  .card.pass {{ border-left: 5px solid #0a7d32; }}
  .card.fail {{ border-left: 5px solid #c62828; }}
  .head {{ display: flex; gap: 1rem; align-items: center; padding: 0.75rem 1rem; }}
  .badge {{ color: #fff; border-radius: 4px; padding: 0.15rem 0.6rem; font-size: 0.85rem; }}
  .mcver {{ font-weight: 600; }}
  .meta {{ color: #888; font-size: 0.85rem; }}
  pre.err {{ margin: 0; padding: 0.75rem 1rem; background: #1a1f29; color: #f2b8b5;
             font-size: 0.8rem; overflow-x: auto; white-space: pre-wrap; }}
</style>
</head>
<body>
<h1>插件兼容性测试报告</h1>
<div class="summary">
  插件：<b>{html.escape(slug)}</b> 版本：<b>{html.escape(version)}</b><br>
  结果：<b style="color:{'#0a7d32' if passed == total else '#c62828'}">{passed} / {total} 通过</b>（仅覆盖启动阶段：加载 → 依赖满足 → onEnable 无异常）
</div>
{''.join(rows)}
</body>
</html>"""

with open("report.html", "w", encoding="utf-8") as f:
    f.write(out)
print(f"report.html 已生成: {passed}/{total} 通过")
