#!/usr/bin/env bash
# 从鬼斩资源站解析并下载插件 jar、硬依赖（depend）与用户勾选的软依赖（softdepend）。
# 依赖的依赖不递归装，用户可把 jar 放进仓库 extra-plugins/ 目录自行补充。
# 用法: resolve-plugin.sh <slug> [version]
# 环境变量: SOFTDEPEND_INSTALL（逗号分隔的 softdepend 插件名，选装）
set -euo pipefail

API="https://resources.guizhanss.com/api/v1"
OUT_DIR="plugins"
mkdir -p "$OUT_DIR"

api() {
  # 带 token 提额；匿名也可读公开资源
  if [ -n "${GUIZHAN_TOKEN:-}" ]; then
    curl -sf -H "Authorization: Bearer $GUIZHAN_TOKEN" "$API$1"
  else
    curl -sf "$API$1"
  fi
}

urlenc() {
  python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$1"
}

#   /projects/{slug}          → data 为平铺对象
#   /projects/{slug}/versions → data 为平铺数组
#   /versions/{id}            → data 为平铺对象，files 直接挂在 data.files
download_version() {
  local project_id="$1" version_id="$2"
  local detail
  detail=$(api "/versions/$version_id")
  echo "$detail" | jq -c '.data.files[]?' | while read -r f; do
    local fid fname
    fid=$(echo "$f" | jq -r '.id')
    fname=$(echo "$f" | jq -r '.name')
    [ -z "$fid" ] || [ "$fid" = "null" ] && continue
    echo "下载文件: $fname"
    curl -sfL -o "$OUT_DIR/$fname" "$API/projects/$project_id/versions/$version_id/download/$fid"
    local expect
    expect=$(echo "$f" | jq -r '.checksum.sha256 // empty')
    if [ -n "$expect" ]; then
      echo "$expect  $OUT_DIR/$fname" | sha256sum -c - >/dev/null \
        || { echo "sha256 校验失败: $fname"; exit 1; }
    fi
  done
}

resolve_project() {
  # 按名称或 slug 搜资源站（name 与 slug 可能不同：GuizhanLibPlugin 的 name 是 GuizhanLib）
  local name="$1"
  api "/projects?q=$(urlenc "$name")&page_size=5" \
    | jq -r --arg n "$name" '.data[]? | select(.slug == $n or .name == $n) | .slug' | head -1
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
  unzip -p "$2" plugin.yml | python3 -c "
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

download_dep() {
  local dep="$1"
  echo "下载依赖: $dep"
  # plugin.yml 里的名字与资源站 slug 不一致时的别名映射
  case "$dep" in
    Slimefun) download_plugin "Slimefun4"; return 0 ;;
  esac
  local dep_slug
  dep_slug=$(resolve_project "$dep")
  if [ -z "$dep_slug" ]; then
    echo "警告: 资源站找不到 $dep（可能导致假失败，可放入 extra-plugins/ 自行补充）"
    return 0
  fi
  download_plugin "$dep_slug"
}

# ---- 主流程：批量模式，逗号分隔多个 slug，一次开服全部测 ----
SLUGS="$1"

# manifest 记录被测插件的 slug→plugin.yml name 映射，供开服后逐插件判定（name 与 slug 可能不同）
MANIFEST="$OUT_DIR/manifest.json"
echo "[]" > "$MANIFEST"

for SLUG in $(echo "$SLUGS" | tr ',' ' '); do
  [ -z "$SLUG" ] && continue
  echo "===== $SLUG ====="
  BEFORE=$(ls "$OUT_DIR" 2>/dev/null | grep -c '\.jar$' || true)
  if ! download_plugin "$SLUG" "${2:-}"; then
    # 记录下载失败，报告里如实展示
    jq --arg s "$SLUG" '. + [{slug:$s, name:$s, jar:null, downloaded:false}]' "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
    continue
  fi
  JAR=$(ls -t "$OUT_DIR"/*.jar | head -1)
  PNAME=$(unzip -p "$JAR" plugin.yml 2>/dev/null | awk '/^name:/{print $2}' | tr -d '\r')
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
jq -r '.[] | "\(.slug) -> \(.name)"' "$MANIFEST" || true
