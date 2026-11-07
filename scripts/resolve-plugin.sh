#!/usr/bin/env bash
# 从鬼斩资源站解析并下载插件 jar、硬依赖（depend）与用户勾选的软依赖（softdepend）。
# 依赖的依赖不递归装，用户可把 jar 放进仓库 extra-plugins/ 目录自行补充。
# 用法: resolve-plugin.sh <slug> [version]
# 环境变量: SOFTDEPEND_INSTALL（逗号分隔的 softdepend 插件名，选装）
# 名字映射不做任何硬编码：全站目录做候选，下载后以 plugin.yml 的真实 name 验证，
# 确认过的 依赖名→slug 映射缓存在 plugins/.name_map.json，随使用越来越全。
set -euo pipefail

API="https://resources.guizhanss.com/api/v1"
OUT_DIR="plugins"
GZ_CACHE=".gzcache"   # 资源站 jar 下载缓存，workflow 按 7 天窗口做 Actions cache
mkdir -p "$OUT_DIR"

api() {
  # 带 token 提额；匿名也可读公开资源
  if [ -n "${GUIZHAN_TOKEN:-}" ]; then
    curl -sf -H "Authorization: Bearer $GUIZHAN_TOKEN" "$API$1"
  else
    curl -sf "$API$1"
  fi
}

#   /projects/{slug}          → data 为平铺对象
#   /projects/{slug}/versions → data 为平铺数组
#   /versions/{id}            → data 为平铺对象，files 直接挂在 data.files
download_version() {
  local project_id="$1" version_id="$2"
  local detail
  detail=$(api "/versions/$version_id")
  echo "$detail" | jq -c '.data.files[]?' | while read -r f; do
    local fid fname cache_file
    fid=$(echo "$f" | jq -r '.id')
    fname=$(echo "$f" | jq -r '.name')
    [ -z "$fid" ] || [ "$fid" = "null" ] && continue
    # 缓存键用文件 id（唯一），文件名里的空格/斜杠替换掉只为了可读
    cache_file="$GZ_CACHE/${fid}__$(echo "$fname" | tr '/ ' '__')"
    if [ -s "$cache_file" ]; then
      echo "命中缓存: $fname"
      cp "$cache_file" "$OUT_DIR/$fname"
    else
      echo "下载文件: $fname"
      curl -sfL -o "$OUT_DIR/$fname" "$API/projects/$project_id/versions/$version_id/download/$fid"
      mkdir -p "$GZ_CACHE" && cp "$OUT_DIR/$fname" "$cache_file"
    fi
    local expect
    expect=$(echo "$f" | jq -r '.checksum.sha256 // empty')
    if [ -n "$expect" ]; then
      echo "$expect  $OUT_DIR/$fname" | sha256sum -c - >/dev/null \
        || { echo "sha256 校验失败: $fname"; exit 1; }
    fi
  done
}

download_plugin() {
  local slug="$1" ver="${2:-}"
  local pid
  pid=$(api "/projects/$slug" | jq -r '.data.id')

  local versions
  # release 渠道可能不存在（404，如 ExoticGarden 只有 master 渠道），失败回落为空
  versions=$(api "/projects/$slug/versions?channel=release" || echo '{"data":[]}')

  local vid=""
  if [ -n "$ver" ]; then
    vid=$(echo "$versions" | jq -r --arg v "$ver" '.data[]? | select(.version == $v) | .id' | head -1)
  fi
  # 未指定版本：优先 release 渠道最新；没有则取默认渠道最新；再没有取全站最新
  if [ -z "$vid" ] && [ "$(echo "$versions" | jq '.data | length' 2>/dev/null || echo 0)" -gt 0 ]; then
    vid=$(echo "$versions" | jq -r '.data | sort_by(.created_at) | reverse | .[0].id // empty')
  fi
  if [ -z "$vid" ]; then
    versions=$(api "/projects/$slug/versions")
    # 默认渠道的构建通常比开发渠道更稳，优先取
    vid=$(echo "$versions" | jq -r '[.data[]? | select(.channel.is_default == true)] | sort_by(.created_at) | reverse | .[0].id // empty')
  fi
  if [ -z "$vid" ]; then
    vid=$(echo "$versions" | jq -r '.data | sort_by(.created_at) | reverse | .[0].id // empty')
  fi
  [ -z "$vid" ] && { echo "找不到版本: $slug $ver"; return 1; }

  echo "下载 $slug (version id: $vid)"
  download_version "$pid" "$vid"
}

read_deps() {  # $1 = depend | softdepend, $2 = jar 路径；兼容列表格式（- X）与行内格式（[X, Y]）
  # unzip 找不到 plugin.yml 时退出码 11，pipefail 会把它传成脚本退出码，必须吞掉
  { unzip -p "$2" plugin.yml 2>/dev/null || true; } | python3 -c "
import re, sys
key, out, grab = sys.argv[1], [], False
for line in sys.stdin:
    s = line.rstrip()
    m = re.match(r'^([A-Za-z_][\w-]*)\s*:(.*)$', s)
    if m:
        if grab:
            break
        grab = m.group(1) == key
        if grab:
            rest = m.group(2).strip().strip('[]')
            out += [x.strip().strip('\'\"') for x in rest.split(',') if x.strip()]
        continue
    if grab:
        li = re.match(r'\s*-\s*(.+)$', s)
        if li:
            out.append(li.group(1).strip().strip('\'\"'))
print('\n'.join(dict.fromkeys(out)))" "$1" | tr -d '\r'
}

# ---- 全站目录：一次拉取所有项目（slug + 站内 name），缓存复用，不硬编码任何别名 ----
CATALOG_FILE="$OUT_DIR/.catalog.json"

fetch_catalog() {
  [ -s "$CATALOG_FILE" ] && return 0
  echo "拉取资源站全量目录…"
  local first total pages p
  first=$(api "/projects?page_size=50&page=1")
  total=$(echo "$first" | jq -r '.pagination.total_items // (.data | length)')
  pages=$(( (total + 49) / 50 ))
  {
    echo "$first" | jq -c '.data[]?'
    for ((p=2; p<=pages; p++)); do
      api "/projects?page_size=50&page=$p" | jq -c '.data[]?' || true
    done
  } | jq -c '{slug, name, downloads}' > "$CATALOG_FILE"
  echo "目录共 $(wc -l < "$CATALOG_FILE") 个项目"
}

# ---- 依赖名→slug 映射缓存（来源全部是 plugin.yml 实名验证的结果）----
NAME_MAP="$OUT_DIR/.name_map.json"
[ -f "$NAME_MAP" ] || echo "{}" > "$NAME_MAP"
map_get() { jq -r --arg k "$1" '.[$k] // empty' "$NAME_MAP"; }
map_put() { jq --arg k "$1" --arg v "$2" '.[$k]=$v' "$NAME_MAP" > "$NAME_MAP.tmp" && mv "$NAME_MAP.tmp" "$NAME_MAP"; }

# 依赖名 → 资源站候选 slug 列表（每行一个）：
# 先精确匹配 slug/name；无命中再按前缀模糊（如依赖 Slimefun → 项目 Slimefun4），
# 模糊候选按下载量排序，最终以 plugin.yml 实名验证兜底，不会误装
dep_candidates() {
  local dep="$1" d
  d=$(echo "$dep" | tr '[:upper:]' '[:lower:]')
  local exact
  # 目录是逐行 JSONL，必须 -s slurp 成数组再过滤
  exact=$(jq -s -r --arg d "$d" '[.[] | select((.slug | ascii_downcase) == $d or ((.name // "") | ascii_downcase) == $d)] | .[].slug' "$CATALOG_FILE")
  if [ -n "$exact" ]; then echo "$exact"; return 0; fi
  jq -s -r --arg d "$d" '[.[] | select((.slug | ascii_downcase | startswith($d)) or ((.name // "") | ascii_downcase | startswith($d)))] | sort_by(-(.downloads // 0)) | .[].slug' "$CATALOG_FILE" | head -5
}

# 从 jar 里取 plugin.yml 的真实 name（去掉引号、\r 与首尾空格）
read_jar_name() {
  unzip -p "$1" plugin.yml 2>/dev/null \
    | awk -F: '/^name:/{gsub(/["'"'"']/,"",$2); gsub(/^[ \t]+|[ \t]+$/,"",$2); gsub(/\r/,"",$2); print $2; exit}'
}

download_dep() {
  local dep="$1"

  # 命中过验证的映射直接复用
  local cached
  cached=$(map_get "$dep")
  if [ -n "$cached" ]; then
    echo "下载依赖: $dep（映射 → $cached）"
    download_plugin "$cached" && return 0
  fi

  fetch_catalog
  echo "下载依赖: $dep"
  local slug
  while IFS= read -r slug; do
    [ -z "$slug" ] && continue
    touch "$OUT_DIR/.dep_marker"
    if ! download_plugin "$slug"; then continue; fi
    # 用 plugin.yml 的真实名字验证：与依赖名完全一致才认可
    local ok=""
    while IFS= read -r cand; do
      [ "$cand" -nt "$OUT_DIR/.dep_marker" ] || continue
      [ "$(read_jar_name "$cand")" = "$dep" ] && ok=1
    done < <(ls -t "$OUT_DIR"/*.jar 2>/dev/null)
    if [ -n "$ok" ]; then
      echo "确认映射: $dep → $slug"
      map_put "$dep" "$slug"
      return 0
    fi
    # 名字对不上：删掉这次新下载的 jar，换下一个候选
    echo "候选 $slug 的 plugin.yml name 与 $dep 不符，弃用"
    while IFS= read -r cand; do
      [ "$cand" -nt "$OUT_DIR/.dep_marker" ] && rm -f "$cand"
    done < <(ls -t "$OUT_DIR"/*.jar 2>/dev/null)
  done < <(dep_candidates "$dep")

  echo "警告: 资源站找不到 $dep（可能导致假失败，可放入 extra-plugins/ 自行补充）"
  return 0
}

# ---- 主流程：批量模式，逗号分隔多个 slug，一次开服全部测 ----
SLUGS="$1"

# manifest 记录被测插件的 slug→plugin.yml name 映射，供开服后逐插件判定（name 与 slug 可能不同）
MANIFEST="$OUT_DIR/manifest.json"
echo "[]" > "$MANIFEST"

for SLUG in $(echo "$SLUGS" | tr ',' ' '); do
  [ -z "$SLUG" ] && continue
  echo "===== $SLUG ====="
  # 只选本 slug 本次下载涉及的 jar：与 marker 比 mtime（依赖同名覆盖会让按路径比对漏判）
  touch "$OUT_DIR/.marker"
  if ! download_plugin "$SLUG" "${2:-}"; then
    # 记录下载失败，报告里如实展示
    jq --arg s "$SLUG" '. + [{slug:$s, name:$s, jar:null, downloaded:false}]' "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
    continue
  fi
  # 最新下载的 jar 可能是无 plugin.yml 的附属产物（如 -all.jar），按新旧顺序挑第一个有效的
  # jar 名普遍带空格，必须按行读不能按词拆
  JAR=""
  while IFS= read -r cand; do
    [ "$cand" -nt "$OUT_DIR/.marker" ] || continue
    if unzip -l "$cand" plugin.yml >/dev/null 2>&1; then JAR="$cand"; break; fi
    # 打出 unzip 的报错，方便在 CI 日志里诊断瞬时下载异常
    unzip -l "$cand" plugin.yml 2>&1 | head -2 || true
  done < <(ls -t "$OUT_DIR"/*.jar 2>/dev/null)
  if [ -z "$JAR" ]; then
    jq --arg s "$SLUG" '. + [{slug:$s, name:$s, jar:null, downloaded:false}]' "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
    echo "警告: $SLUG 下载的 jar 均无 plugin.yml，跳过依赖解析"
    continue
  fi
  PNAME=$(read_jar_name "$JAR")
  jq --arg s "$SLUG" --arg n "${PNAME:-$SLUG}" --arg j "$(basename "$JAR")" \
    '. + [{slug:$s, name:$n, jar:$j, downloaded:true}]' "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"

  # 依赖解析只针对被测插件本体（依赖的依赖不递归，走 extra-plugins/ 自备）
  for dep in $(read_deps depend "$JAR"); do
    download_dep "$dep"
  done
  SOFT_SELECTED=",${SOFTDEPEND_INSTALL:-},"
  for dep in $(read_deps softdepend "$JAR"); do
    if [ "$dep" = "GuizhanLibPlugin" ] || [[ "$SOFT_SELECTED" == *",$dep,"* ]]; then
      download_dep "$dep"
    fi
  done
done

# 同名依赖被多个插件重复下载时按插件名去重：只保留每个 plugin.yml name 的最新 jar
python3 - "$OUT_DIR" <<'EOF'
import json, glob, os, zipfile, sys
d = sys.argv[1]
keep = {}
for j in glob.glob(os.path.join(d, "*.jar")):
    try:
        with zipfile.ZipFile(j) as z:
            name = z.read("plugin.yml").decode("utf-8", "ignore")
    except Exception:
        os.remove(j)  # 连 plugin.yml 都没有的 jar 装上也无效
        continue
    m = None
    for line in name.splitlines():
        if line.startswith("name:"):
            m = line.split(":", 1)[1].strip().strip("'\"").strip("\r")
            break
    if m:
        keep.setdefault(m, []).append(j)
for name, jars in keep.items():
    for old in sorted(jars, key=os.path.getmtime)[:-1]:
        os.remove(old)  # 同名只留最新一份，避免 Bukkit 报 duplicate plugin
EOF

# 用户自备 jar（解决依赖的依赖等特殊场景）
if [ -d extra-plugins ]; then
  cp extra-plugins/*.jar "$OUT_DIR"/ 2>/dev/null || true
fi

echo "最终插件清单: $(ls "$OUT_DIR"/*.jar | wc -l) 个 jar"
echo "已确认的名字映射:"
jq -r 'to_entries[] | "  \(.key) -> \(.value)"' "$NAME_MAP" || true
jq -r '.[] | "\(.slug) -> \(.name)"' "$MANIFEST" || true
