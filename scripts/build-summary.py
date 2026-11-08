#!/usr/bin/env python3
"""汇总各版本 result-*.json 为 md 表格 + csv（artifact 用）。
用法: build-summary.py（在含 results/ 目录的仓库根目录运行）
产物: summary.md + summary.csv
"""
import csv
import json
import pathlib

RESULTS_DIR = pathlib.Path("results")


def ver_key(v: str):
    # 版本列按数值排序（1.20.6 应排在 1.21.1 前），非数字段兜底按字符串
    parts = []
    for seg in v.split("."):
        parts.append((0, int(seg)) if seg.isdigit() else (1, seg))
    return parts


def load():
    data = {}
    for f in sorted(RESULTS_DIR.glob("result-*.json")):
        d = json.loads(f.read_text(encoding="utf-8"))
        data[d.get("mc_version", f.stem)] = d
    return data


def main():
    data = load()
    if not data:
        raise SystemExit("results/ 下没有 result-*.json，无法汇总")

    versions = sorted(data, key=ver_key)
    platform = next(iter(data.values())).get("platform", "paper")

    # 插件全集按名字 A-Z（大小写不敏感）；status_map[插件][版本] 记录该版本状态
    names = set()
    status_map = {}
    for v, d in data.items():
        for r in d.get("results", []):
            names.add(r["name"])
            status_map.setdefault(r["name"], {})[v] = r["status"]

    ordered = sorted(names, key=str.lower)

    # markdown
    md = [
        f"| 测试端 {platform} | " + " | ".join(versions) + " |",
        "|" + " :---: |" * (len(versions) + 1),
    ]
    for n in ordered:
        cells = ["✅" if status_map[n].get(v) == "success" else "❌" for v in versions]
        md.append(f"| {n} | " + " | ".join(cells) + " |")
    pathlib.Path("summary.md").write_text("\n".join(md) + "\n", encoding="utf-8")

    # csv（status 原样落盘，success/failure 比 emoji 更适合二次处理）
    with open("summary.csv", "w", newline="", encoding="utf-8-sig") as fp:
        w = csv.writer(fp)
        w.writerow(["plugin"] + [f"{platform} {v}" for v in versions])
        for n in ordered:
            w.writerow(
                [n] + ["success" if status_map[n].get(v) == "success" else "failure" for v in versions]
            )

    print(f"汇总完成: {len(ordered)} 个插件 x {len(versions)} 个版本 -> summary.md / summary.csv")


if __name__ == "__main__":
    main()
