#!/usr/bin/env bash
# 下载 Paper 服务端并启动一次，按日志对 manifest 里每个插件逐个判定。
# 用法: run-server.sh <mc_version> [platform]
# 产物: console.log + result-{mcver}.json（含 per-plugin 判定数组）
set -euo pipefail

# 出错定位：任意命令失败时打印行号和现场，CI 里直接看这条就能知道死在哪
# 诊断输出必须全走 stderr，否则会混进命令替换捕获的判定结果
set -E
# JVM 崩溃（如 spark 原生 SIGSEGV）时禁写 core dump：4G 堆的转储能卡住进程几分钟到更久
ulimit -c 0
trap 'rc=$?
  echo "::error::run-server.sh 第 ${LINENO} 行命令失败 (exit $rc)" >&2
  echo "失败位置上下文:" >&2
  sed -n "$((LINENO-3)),$((LINENO+3))p" "$0" | sed "s/^/  | /" >&2
  if [ -f console.log ]; then
    echo "当前 console.log 末尾 20 行:" >&2
    tail -20 console.log | sed "s/^/  | /" >&2
  fi
' ERR

MCVER="${1// /}"   # 逗号后带空格的输入（"1.20.4, 1.20.6"）会带出空格
PLATFORM="${2:-paper}"
# 开服测试阶段硬上限 10 分钟：无论上游传什么，超出部分截断
START_TIMEOUT="${START_TIMEOUT:-600}"
[ "$START_TIMEOUT" -gt 600 ] 2>/dev/null && START_TIMEOUT=600

JAVA_BIN="${JAVA_HOME_25_X64:-}/bin/java"
JAVA_VER=25

# 分级：MC ≤ 1.17 最高 Java 16（服务端不支持 17+）；
# MC ≤ 1.18.1 最高 Java 17（服务端不支持 21+）；
# MC ≤ 1.19.1 最高 Java 21（旧版 ASM 不支持 Java 25 的 class 文件版本，启动会炸）；
# 其余默认 Java 25。注意先判低版本再判高版本，否则低版本会被高版本拦截
NEEDS16=$(printf '%s\n1.17\n' "$MCVER" | sort -V | head -1)
if [ "$NEEDS16" = "$MCVER" ] && [ -n "${JAVA_HOME_16_X64:-}" ]; then
  JAVA_BIN="${JAVA_HOME_16_X64}/bin/java"
  JAVA_VER=16
else
  NEEDS17=$(printf '%s\n1.18.1\n' "$MCVER" | sort -V | head -1)
  if [ "$NEEDS17" = "$MCVER" ] && [ -n "${JAVA_HOME_17_X64:-}" ]; then
    JAVA_BIN="${JAVA_HOME_17_X64}/bin/java"
    JAVA_VER=17
  else
    NEEDS21=$(printf '%s\n1.19.1\n' "$MCVER" | sort -V | head -1)
    if [ "$NEEDS21" = "$MCVER" ] && [ -n "${JAVA_HOME_21_X64:-}" ]; then
      JAVA_BIN="${JAVA_HOME_21_X64}/bin/java"
      JAVA_VER=21
    fi
  fi
fi
# MC 1.21 特例：强制 Java 21 启动，规避 spark 崩溃问题
# https://github.com/lucko/spark/issues/548
if [ "$MCVER" = "1.21" ] && [ -n "${JAVA_HOME_21_X64:-}" ]; then
  JAVA_BIN="${JAVA_HOME_21_X64}/bin/java"
  JAVA_VER=21
fi
# NEEDS25=$(printf '%s\n26\n' "$MCVER" | sort -V | tail -1)
# if [ "$NEEDS25" = "$MCVER" ]; then
#   JAVA_BIN="${JAVA_HOME_25_X64:-}/bin/java"
#   JAVA_VER=25
# else
#   NEEDS21=$(printf '%s\n1.20.5\n' "$MCVER" | sort -V | tail -1)
#   if [ "$NEEDS21" = "$MCVER" ]; then
#     JAVA_BIN="${JAVA_HOME_21_X64:-}/bin/java"
#     JAVA_VER=21
#   else
#     JAVA_BIN="${JAVA_HOME_17_X64:-}/bin/java"
#     JAVA_VER=17
#   fi
# fi

[ -x "$JAVA_BIN" ] || JAVA_BIN="java"
echo "使用 Java $JAVA_VER ($JAVA_BIN)"

# Paper 下载（fill.papermc.io v3 API），带本地缓存（workflow 用 .paper-cache 做 Actions cache）
# 缓存过期：14 天未访问的缓存 jar 清掉，避免长期占用 GitHub 缓存额度
find .paper-cache -type f -mtime +14 -delete 2>/dev/null || true
CACHE_JAR=".paper-cache/server-$PLATFORM-$MCVER.jar"
BUILD_JSON=$(curl -sf "https://fill.papermc.io/v3/projects/$PLATFORM/versions/$MCVER/builds/latest")
SERVER_URL=$(echo "$BUILD_JSON" | jq -r '.downloads["server:default"].url')
[ -n "$SERVER_URL" ] && [ "$SERVER_URL" != "null" ] || { echo "找不到 $PLATFORM $MCVER 的服务端构建"; exit 1; }
if [ -s "$CACHE_JAR" ]; then
  cp "$CACHE_JAR" server.jar
  echo "命中服务端缓存: $CACHE_JAR"
else
  curl -sfL -o server.jar "$SERVER_URL"
  mkdir -p .paper-cache && cp server.jar "$CACHE_JAR"
  echo "已下载 $PLATFORM $MCVER 服务端（已写入缓存）"
fi

echo "eula=true" > eula.txt
echo "写好 eula/server.properties，准备启动服务端"
cat > server.properties <<EOF
online-mode=false
sync-chunk-writes=false
spawn-protection=0
view-distance=4
EOF

# 服务端起来后不会自己退出，干等 timeout 会白跑满 START_TIMEOUT。
# 后台启动，轮询日志见到 Done ( 即认为启动成功，主动停服收工。
# 卡死状态的服务端会忽略 SIGTERM，kill 后必须限时 wait 并用 SIGKILL 补刀，
# 否则 wait 无限挂起，整个步骤曾因此跑出 28 分钟
stop_server() {
  kill "$SERVER_PID" 2>/dev/null || true
  for _ in $(seq 1 15); do
    kill -0 "$SERVER_PID" 2>/dev/null || break
    sleep 1
  done
  kill -9 "$SERVER_PID" 2>/dev/null || true
  # 主动 kill 的进程 wait 必返 143；ERR trap 不受 set +e 约束，只有 || 列表能豁免
  wait "$SERVER_PID" || true
}

"$JAVA_BIN" -Xmx4G -jar server.jar nogui > console.log 2>&1 &
SERVER_PID=$!
echo "服务端已后台启动 (PID $SERVER_PID)，等待 Done（上限 ${START_TIMEOUT}s）"
timeout_rc=0
DEADLINE=$(( $(date +%s) + START_TIMEOUT ))
while kill -0 "$SERVER_PID" 2>/dev/null; do
  # Done 后再等几秒，让各插件的 Enabling / 报错日志都落盘再判
  if grep -q "Done (" console.log 2>/dev/null; then
    echo "检测到 Done，等 5s 收日志后停服"
    sleep 5
    stop_server
    echo "服务端已停止，开始判定"
    break
  fi
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "启动超时（${START_TIMEOUT}s），强制停服"
    timeout_rc=124
    stop_server
    break
  fi
  sleep 2
done
echo "服务端轮询循环结束 (timeout_rc=$timeout_rc, 进程存活=$(kill -0 "$SERVER_PID" 2>/dev/null && echo yes || echo no))"

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
        # 2>/dev/null：head 拿满行数先退，grep 被断管会刷 Broken pipe 噪音
        # || true：grep 无匹配时 pipefail 让赋值返回 1，会截断整批判定
        error="$error
$(grep -iE -B1 -A8 "Could not load plugin|Invalid plugin.yml|Cannot load plugin|Skipping loading addon" console.log 2>/dev/null | head -30 || true)"
      elif grep -qiE "Error occurred while enabling $name( |$)|Could not load plugin ?'?$name'?|while enabling $name( |$)" console.log; then
        status=failure
        error=$(grep -iE -B2 -A25 "Error occurred while enabling $name( |$)|while enabling $name( |$)" console.log 2>/dev/null | head -40 || true)
      else
        status=success
      fi
    fi
    jq -nc --arg slug "$slug" --arg name "$name" --arg status "$status" --arg error "$error" \
      '{slug:$slug, name:$name, status:$status, error_excerpt:$error}'
  done
}

RESULTS=$(judge_results)
echo "逐插件判定完成，开始汇总结果"
# 逐行对象合并成数组；多行 pretty JSON 直接拼 [$RESULTS] 会因缺逗号非法
RESULT_ARR=$(echo "$RESULTS" | jq -s -c '.' 2>/dev/null || echo '[]')
PASSED=$(echo "$RESULT_ARR" | jq '[.[] | select(.status == "success")] | length')
TOTAL=$(echo "$RESULT_ARR" | jq 'length')

# 判定数组可能超过单参数 128KiB 上限（MAX_ARG_STRLEN），必须落盘传给 jq，
# 不能用 --argjson 直接塞命令行（128 插件全测时曾炸出 Argument list too long）
printf '%s' "$RESULT_ARR" > .result_arr.json
jq -n \
  --arg mc "$MCVER" --arg platform "$PLATFORM" --arg java "$JAVA_VER" \
  --arg server_status "$SERVER_OK" \
  --argjson passed "$PASSED" --argjson total "$TOTAL" \
  --slurpfile results .result_arr.json \
  '{mc_version:$mc, platform:$platform, java:$java,
    server_status:$server_status, passed:$passed, total:$total,
    results:$results[0], judged_at:(now | todateiso8601)}' > "result-${MCVER}.json"
rm -f .result_arr.json
echo "result-${MCVER}.json 已写出"

echo "测试结果: $PASSED/$TOTAL 通过 (MC $MCVER)"
exit 0
