#!/usr/bin/env bash
# 从鬼斩资源站解析并下载插件 jar 及其硬依赖（depend），深度 1 层。
# 用法: resolve-plugin.sh <slug> [version]
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

# 统一响应壳: {code, message, data, pagination}; 列表可能在 data.items 或 data
jq_items() {
  jq -r '[.data.items[]?, .data[]?] | .[]'
}

download_version() {
  local project_id="$1" version_id="$2"
  local detail
  detail=$(api "/versions/$version_id")
  echo "$detail" | jq_items | jq -r '.files[]? | [.id, .name] | @tsv' | while IFS=$'\t' read -r fid fname; do
    [ -z "$fid" ] && continue
    echo "下载文件: $fname"
    curl -sfL -o "$OUT_DIR/$fname" "$API/projects/$project_id/versions/$version_id/download/$fid"
    local expect
    expect=$(echo "$detail" | jq -r --arg n "$fname" '[.data.items[]?, .data[]?][0].files[]? | select(.name == $n) | .checksum.sha256 // empty')
    if [ -n "$expect" ]; then
      echo "$expect  $OUT_DIR/$fname" | sha256sum -c - >/dev/null \
        || { echo "sha256 校验失败: $fname"; exit 1; }
    fi
  done
}

resolve_project_by_name() {
  # 按插件名搜资源站，返回 (id, slug)；找不到输出空
  local name="$1"
  api "/projects?q=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$name")&page_size=5" \
    | jq_items | jq -r 'select(.name == $n) | "\(.id)\t\(.slug)"' --arg n "$name" | head -1
}

download_plugin() {
  local slug="$1" ver="${2:-}"
  local proj
  proj=$(api "/projects/$slug")
  local pid
  pid=$(echo "$proj" | jq -r '[.data.items[]?, .data[]?][0].id // .data.id')

  local versions
  versions=$(api "/projects/$slug/versions?channel=release")
  if [ -n "$ver" ]; then
    vid=$(echo "$versions" | jq -r --arg v "$ver" '[.data.items[]?, .data[]?] | map(select(.version == $v))[0].id // empty')
  fi
  # 版本号匹配不到时回落到最新 release（资源站 version 字段可能与用户认知不一致）
  if [ -z "${vid:-}" ]; then
    vid=$(echo "$versions" | jq -r '[.data.items[]?, .data[]?] | sort_by(.created_at) | reverse | .[0].id // empty')
  fi
  [ -z "${vid:-}" ] && { echo "找不到版本: $slug $ver"; return 1; }

  echo "下载 $slug (version id: $vid)"
  download_version "$pid" "$vid"
}

# ---- 主流程 ----
SLUG="$1"
VER="${2:-}"
download_plugin "$SLUG" "$VER"

# 解析主插件 plugin.yml 的 depend，逐个下载最新 release（深度 1，不递归）
MAIN_JAR=$(ls -t "$OUT_DIR"/*.jar | head -1)
PLUGIN_NAME=$(unzip -p "$MAIN_JAR" plugin.yml | awk '/^name:/{print $2}' | tr -d '\r')
echo "主插件: $PLUGIN_NAME"

DEPS=$(unzip -p "$MAIN_JAR" plugin.yml \
  | sed -n '/^depend:/,/^[a-z_]*:/p' | sed '$d' \
  | grep -oP '\[\K[^\]]+' | tr ',' '\n' | tr -d " '" | tr -d '"' | sed '/^$/d' || true)

for dep in $DEPS; do
  [ "$dep" = "Slimefun" ] && continue  # Slimefun4 不在资源站，另行处理
  echo "解析硬依赖: $dep"
  line=$(resolve_project_by_name "$dep")
  if [ -z "$line" ]; then
    echo "警告: 资源站找不到依赖 $dep（可能导致假失败）"
    continue
  fi
  dep_id=$(echo "$line" | cut -f1)
  dep_slug=$(echo "$line" | cut -f2)
  download_plugin "$dep_slug"
done

echo "PLUGIN_NAME=$PLUGIN_NAME" >> "$GITHUB_ENV"
