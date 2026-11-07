#!/usr/bin/env python3
"""汇总所有 result-*.json（批量格式），生成单页 HTML 测试报告 report.html。"""
import glob
import html
import json

batches = []
for path in sorted(glob.glob("results/result-*.json")):
    with open(path, encoding="utf-8") as f:
        batches.append(json.load(f))

if not batches:
    batches = [{"mc_version": "?", "platform": "?", "server_status": "no",
                "passed": 0, "total": 1, "java": "?",
                "results": [{"slug": "?", "name": "?", "status": "failure",
                             "error_excerpt": "未找到任何结果文件"}]}]

sections = []
grand_pass = grand_total = 0
for b in batches:
    grand_pass += b.get("passed", 0)
    grand_total += b.get("total", 0)
    cards = []
    for r in b.get("results", []):
        ok = r.get("status") == "success"
        color, badge = ("#0a7d32", "✔ 启动成功") if ok else ("#c62828", "✘ 启动失败")
        excerpt = r.get("error_excerpt") or ""
        detail = f'<pre class="err">{html.escape(excerpt)}</pre>' if excerpt else ""
        cards.append(f"""
    <div class="card {'pass' if ok else 'fail'}">
      <div class="head">
        <span class="badge" style="background:{color}">{badge}</span>
        <span class="mcver">{html.escape(str(r.get('name') or r.get('slug', '?')))}</span>
        <span class="meta">@{html.escape(str(r.get('slug', '')))}</span>
      </div>
      {detail}
    </div>""")
    server_badge = "服务端正常" if b.get("server_status") == "yes" else "⚠ 服务端未能完成启动"
    sections.append(f"""
  <h2>MC {html.escape(str(b.get('mc_version', '?')))} · {html.escape(str(b.get('platform', '?')))} · Java {html.escape(str(b.get('java', '?')))}
      — <b style="color:{'#0a7d32' if b.get('passed') == b.get('total') else '#c62828'}">{b.get('passed', 0)} / {b.get('total', 0)} 通过</b>
      <span class="meta">{server_badge}</span></h2>
  {''.join(cards) or '<p class="meta">无插件结果</p>'}""")

slug_count = len({r.get("slug") for b in batches for r in b.get("results", [])})
out = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>兼容性测试报告</title>
<style>
  body {{ font-family: system-ui, sans-serif; max-width: 860px; margin: 2rem auto; padding: 0 1rem; background:#11151c; color:#e6e6e6; }}
  h1 {{ font-size: 1.4rem; }}
  h2 {{ font-size: 1.05rem; margin-top: 2rem; }}
  .summary {{ margin-bottom: 1.5rem; color:#aaa; }}
  .card {{ border: 1px solid #333; border-radius: 8px; margin-bottom: 1rem; overflow: hidden; }}
  .card.pass {{ border-left: 5px solid #0a7d32; }}
  .card.fail {{ border-left: 5px solid #c62828; }}
  .head {{ display: flex; gap: 1rem; align-items: center; padding: 0.75rem 1rem; flex-wrap: wrap; }}
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
  共 <b>{slug_count}</b> 个插件，总体 <b style="color:{'#0a7d32' if grand_pass == grand_total else '#c62828'}">{grand_pass} / {grand_total} 通过</b><br>
  仅覆盖启动阶段：加载 → 依赖满足 → onEnable 无异常（一次开服多插件并行判定）
</div>
{''.join(sections)}
</body>
</html>"""

with open("report.html", "w", encoding="utf-8") as f:
    f.write(out)
print(f"report.html 已生成: {grand_pass}/{grand_total} 通过")
