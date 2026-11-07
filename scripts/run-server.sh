#!/usr/bin/env bash
# 下载 Paper 服务端并启动一次，按日志对 manifest 里每个插件逐个判定。
# 用法: run-server.sh <mc_version> [platform]
# 产物: console.log + result-{mcver}.json（含 per-plugin 判定数组）
set -euo pipefail

MCVER="${1// /}"   # 逗号后带空格的输入（"1.20.4, 1.20.6"）会带出空格
PLATFORM="${2:-paper}"
START_TIMEOUT="${START_TIMEOUT:-900}"

# JDK 选择: 1.20.5+ 需要 Java 21，更早需要 17
NEEDS21=$(printf '%s\n1.20.5\n' "$MCVER" | sort -V | tail -1)
if [ "$NEEDS21" = "$MCVER" ]; then
  JAVA_BIN="${JAVA_HOME_21_X64:-}/bin/java"
  JAVA_VER=21
else
  JAVA_BIN="${JAVA_HOME_17_X64:-}/bin/java"
  JAVA_VER=17
fi
[ -x "$JAVA_BIN" ] || JAVA_BIN="java"
echo "使用 Java $JAVA_VER ($JAVA_BIN)"

# Paper 下载（fill.papermc.io v3 API）
BUILD_JSON=$(curl -sf "https://fill.papermc.io/v3/projects/$PLATFORM/versions/$MCVER/builds/latest")
SERVER_URL=$(echo "$BUILD_JSON" | jq -r '.downloads["server:default"].url')
[ -n "$SERVER_URL" ] && [ "$SERVER_URL" != "null" ] || { echo "找不到 $PLATFORM $MCVER 的服务端构建"; exit 1; }
curl -sfL -o server.jar "$SERVER_URL"
echo "已下载 $PLATFORM $MCVER 服务端"

echo "eula=true" > eula.txt
cat > server.properties <<EOF
online-mode=false
sync-chunk-writes=false
spawn-protection=0
view-distance=4
EOF

set +e
timeout "$START_TIMEOUT" "$JAVA_BIN" -Xmx4G -jar server.jar nogui > console.log 2>&1
timeout_rc=$?
set -e

# ---- 服务端层面判定 ----
SERVER_OK=no
SERVER_EXCERPT=""
if grep -q "Done (" console.log; then
  SERVER_OK=yes
elif [ "$timeout_rc" -eq 124 ]; then
  SERVER_EXCERPT="服务端启动超时（${START_TIMEOUT}s）"
  SERVER_EXCERPT="$SERVER_EXCERPT
$(tail -30 console.log)"
else
  SERVER_EXCERPT="服务端启动崩溃
$(tail -40 console.log)"
fi

# ---- 逐插件判定 ----
# 成功 = 服务端 Done 且日志有 "Enabling {name}" 且没有该插件的加载/启用报错
judge_results() {
  local manifest="plugins/manifest.json"
  jq -c '.[]' "$manifest" | while read -r entry; do
    local slug name status error
    slug=$(echo "$entry" | jq -r '.slug')
    name=$(echo "$entry" | jq -r '.name')
    downloaded=$(echo "$entry" | jq -r '.downloaded')
    status=failure
    error=""
    if [ "$downloaded" != "true" ]; then
      error="从资源站下载失败（slug 或版本号不存在）"
    elif [ "$SERVER_OK" != "yes" ]; then
      error="$SERVER_EXCERPT"
    else
      if ! grep -qE "^\\[[0-9:]+ INFO\\]: Enabling $name( |$)" console.log \
         && ! grep -q "Enabling $name v" console.log; then
        status=failure
        error="日志中未出现 Enabling $name（可能依赖缺失被 Bukkit 拒载）"
        error="$error
$(grep -iE -B1 -A8 "Could not load plugin|Invalid plugin.yml|Cannot load plugin|Skipping loading addon" console.log | head -30)"
      elif grep -qiE "Error occurred while enabling $name( |$)|Could not load plugin ?'?$name'?|while enabling $name( |$)" console.log; then
        status=failure
        error=$(grep -iE -B2 -A25 "Error occurred while enabling $name( |$)|while enabling $name( |$)" console.log | head -40)
      else
        status=success
      fi
    fi
    jq -n --arg slug "$slug" --arg name "$name" --arg status "$status" --arg error "$error" \
      '{slug:$slug, name:$name, status:$status, error_excerpt:$error}'
  done
}

RESULTS=$(judge_results)
PASSED=$(echo "$RESULTS" | jq -s '[.[] | select(.status == "success")] | length')
TOTAL=$(echo "$RESULTS" | jq -s 'length')

jq -n \
  --arg mc "$MCVER" --arg platform "$PLATFORM" --arg java "$JAVA_VER" \
  --argjson results "[$RESULTS]" \
  --arg server_status "$SERVER_OK" \
  --argjson passed "$PASSED" --argjson total "$TOTAL" \
  '{mc_version:$mc, platform:$platform, java:$java,
    server_status:$server_status, passed:$passed, total:$total,
    results:$results, judged_at:(now | todateiso8601)}' > "result-${MCVER}.json"

echo "测试结果: $PASSED/$TOTAL 通过 (MC $MCVER)"
exit 0
