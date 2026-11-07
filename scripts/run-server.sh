#!/usr/bin/env bash
# 下载 Paper 服务端并启动，按日志判定插件是否成功启用。
# 用法: run-server.sh <mc_version> [platform]
# 产物: console.log + result.json（status: success | failure）
set -euo pipefail

MCVER="$1"
PLATFORM="${2:-paper}"
START_TIMEOUT="${START_TIMEOUT:-600}"
PLUGIN_NAME="${PLUGIN_NAME:-unknown}"

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
timeout "$START_TIMEOUT" "$JAVA_BIN" -Xmx2G -jar server.jar nogui > console.log 2>&1
timeout_rc=$?
set -e

STATUS=failure
ERROR_EXCERPT=""
if grep -q "Done (" console.log; then
  # 服务端起来了，还要看插件自身 onEnable 有没有炸（服务端会照常 Done）
  if grep -qiE "Error occurred while enabling $PLUGIN_NAME|Could not load plugin $PLUGIN_NAME|Cannot load configuration.*$PLUGIN_NAME" console.log; then
    ERROR_EXCERPT=$(grep -iE -B2 -A20 "Error occurred while enabling $PLUGIN_NAME|Could not load plugin $PLUGIN_NAME" console.log | head -40 || true)
  else
    STATUS=success
  fi
elif [ "$timeout_rc" -eq 124 ]; then
  ERROR_EXCERPT="服务端启动超时（${START_TIMEOUT}s），可能卡在依赖加载"
  ERROR_EXCERPT="$ERROR_EXCERPT
$(tail -30 console.log)"
else
  ERROR_EXCERPT=$(tail -40 console.log)
fi

jq -n \
  --arg slug "${PLUGIN_SLUG:-}" \
  --arg version "${PLUGIN_VERSION:-}" \
  --arg mc "$MCVER" \
  --arg platform "$PLATFORM" \
  --arg status "$STATUS" \
  --arg java "$JAVA_VER" \
  --arg error "$ERROR_EXCERPT" \
  '{slug:$slug, version:$version, mc_version:$mc, platform:$platform,
    status:$status, java:$java, error_excerpt:$error,
    judged_at:(now | todateiso8601)}' > "result-${MCVER}.json"

echo "测试结果: $STATUS (MC $MCVER)"
exit 0
