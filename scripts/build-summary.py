#!/usr/bin/env python3
"""汇总各版本 result-*.json 为 md 表格 + csv（artifact 用）。
用法: build-summary.py（在含 results/ 目录的仓库根目录运行）
产物: summary.md + summary.csv
"""
import csv
import json
import os
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


def expected_versions():
    # 被 cancel 的版本不会写出结果文件，靠外部传入的期望版本保住表格列
    raw = os.environ.get("EXPECTED_VERSIONS", "")
    return {v.strip() for v in raw.split(",") if v.strip()}


def cell_status(data, status_map, name, v):
    d = data.get(v)
    # 结果文件缺失或服务端未完成启动，都没有逐插件判定，属于无数据而非失败
    if d is None or d.get("server_status", "yes") != "yes":
        return "-"
    st = status_map.get(name, {}).get(v)
    return st if st in ("success", "failure") else "-"


def main():
    data = load()
    versions = sorted(set(data) | expected_versions(), key=ver_key)
    if not versions:
        raise SystemExit("results/ 下没有 result-*.json，且未指定期望版本，无法汇总")

    platform = (next(iter(data.values()), {}).get("platform")
                or os.environ.get("EXPECTED_PLATFORM") or "paper")

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
    symbol = {"success": "✅", "failure": "❌"}
    for n in ordered:
        cells = [symbol.get(cell_status(data, status_map, n, v), "-") for v in versions]
        md.append(f"| {n} | " + " | ".join(cells) + " |")
    pathlib.Path("summary.md").write_text("\n".join(md) + "\n", encoding="utf-8")

    # csv（状态原样落盘，success/failure/- 比 emoji 更适合二次处理）
    with open("summary.csv", "w", newline="", encoding="utf-8-sig") as fp:
        w = csv.writer(fp)
        w.writerow(["plugin"] + [f"{platform} {v}" for v in versions])
        for n in ordered:
            w.writerow([n] + [cell_status(data, status_map, n, v) for v in versions])

    print(f"汇总完成: {len(ordered)} 个插件 x {len(versions)} 个版本 -> summary.md / summary.csv")


if __name__ == "__main__":
    main()
