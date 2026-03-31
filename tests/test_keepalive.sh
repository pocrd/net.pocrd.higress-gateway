#!/bin/bash

# =============================================================================
# Higress HTTPS/WSS Keepalive 测试脚本
# 测试 TLS 连接复用和 keepalive 配置，减少 mTLS 握手成本
# =============================================================================

set -e

BASE_URL="https://xz.caringfamily.cn"
CLIENT_CERT="../certs/files/bagua/testFactory/devices/device001/device001-fullchain.crt"
CLIENT_KEY="../certs/files/bagua/testFactory/devices/device001/device001.key"

echo "=============================================="
echo "Higress HTTPS/WSS Keepalive 测试"
echo "=============================================="
echo ""

# -----------------------------------------------------------------------------
# 测试 1: 基础 HTTPS 连接 + 检查 Connection 头 (HTTP/1.1)
# -----------------------------------------------------------------------------
echo "测试 1: HTTPS 连接 Keepalive 检测 (HTTP/1.1)"
echo "----------------------------------------------"

RESPONSE=$(curl -s -I -X GET "${BASE_URL}/api/health" \
  --cert "${CLIENT_CERT}" \
  --key "${CLIENT_KEY}" \
  --http1.1 \
  -w "\nhttp_code:%{http_code}\ntime_total:%{time_total}\n")

echo "$RESPONSE" | head -20
echo ""

# 提取 Connection 头
CONNECTION_HEADER=$(echo "$RESPONSE" | grep -i "^connection:" | tr -d '\r\n' || echo "Not found")
echo "Connection 头：$CONNECTION_HEADER"

if echo "$CONNECTION_HEADER" | grep -qi "keep-alive"; then
    echo "✅ Keepalive 已启用"
else
    echo "⚠️  未检测到 Keep-Alive 头（可能是 HTTP/2）"
fi

echo ""

# -----------------------------------------------------------------------------
# 测试 2: 多次请求复用连接测试 (HTTP/1.1)
# -----------------------------------------------------------------------------
echo "测试 2: 多次请求连接复用测试 (HTTP/1.1)"
echo "----------------------------------------------"
echo "发起 5 次连续请求，观察连接是否复用..."
echo ""

TOTAL_TIME=0
for i in {1..5}; do
    START_TIME=$(date +%s%N)
    
    curl -s -o /dev/null -w "%{http_code}" -X GET "${BASE_URL}/api/health" \
      --cert "${CLIENT_CERT}" \
      --key "${CLIENT_KEY}" \
      --http1.1 \
      --max-time 5 > /dev/null 2>&1
    
    END_TIME=$(date +%s%N)
    ELAPSED=$(( (END_TIME - START_TIME) / 1000000 ))
    TOTAL_TIME=$((TOTAL_TIME + ELAPSED))
    
    echo "请求 $i: ${ELAPSED}ms"
done

AVG_TIME=$((TOTAL_TIME / 5))
echo ""
echo "平均响应时间：${AVG_TIME}ms"

if [ $AVG_TIME -lt 100 ]; then
    echo "✅ 连接可能已复用（平均响应时间 < 100ms）"
elif [ $AVG_TIME -lt 300 ]; then
    echo "⚠️  连接复用情况一般（平均响应时间 100-300ms）"
else
    echo "❌ 连接可能未复用（平均响应时间 > 300ms，可能存在重复 TLS 握手）"
fi

echo ""

# -----------------------------------------------------------------------------
# 测试 3: HTTP/1.1 Keepalive 专用测试
# -----------------------------------------------------------------------------
echo "测试 3: HTTP/1.1 Keepalive 详细检测"
echo "----------------------------------------------"

echo "第一次请求（建立连接）："
RESP1=$(curl -s -v -X GET "${BASE_URL}/api/health" \
  --cert "${CLIENT_CERT}" \
  --key "${CLIENT_KEY}" \
  --http1.1 \
  -o /dev/null 2>&1 | grep -E "Connection:|< HTTP|Re-using existing connection" || echo "未捕获到关键信息")
echo "$RESP1"
echo ""

echo "立即发起第二次请求（期望复用连接）："
RESP2=$(curl -s -v -X GET "${BASE_URL}/api/health" \
  --cert "${CLIENT_CERT}" \
  --key "${CLIENT_KEY}" \
  --http1.1 \
  -o /dev/null 2>&1 | grep -E "Connection:|< HTTP|Re-using existing connection" || echo "未捕获到关键信息")
echo "$RESP2"
echo ""

if echo "$RESP2" | grep -q "Re-using existing connection"; then
    echo "✅ 检测到连接复用！"
elif echo "$RESP2" | grep -qi "Connection: keep-alive"; then
    echo "✅ Keep-Alive 已启用（但未观察到连接复用）"
else
    echo "❌ 未检测到连接复用或 Keep-Alive"
fi

echo ""

# -----------------------------------------------------------------------------
# 测试 4: TLS 握手时间分析 (HTTP/1.1)
# -----------------------------------------------------------------------------
echo "测试 4: TLS 握手时间分析 (HTTP/1.1)"
echo "----------------------------------------------"
echo "首次握手（完整 TLS 握手）："

FIRST_HANDSHAKE=$(curl -s -o /dev/null -w "握手时间：%{time_appconnect}s\n总时间：%{time_total}s\n" \
  -X GET "${BASE_URL}/api/health" \
  --cert "${CLIENT_CERT}" \
  --key "${CLIENT_KEY}" \
  --http1.1 \
  --max-time 10)

echo "$FIRST_HANDSHAKE"

echo ""
echo "立即发起第二次请求（期望会话复用）："

SECOND_HANDSHAKE=$(curl -s -o /dev/null -w "握手时间：%{time_appconnect}s\n总时间：%{time_total}s\n" \
  -X GET "${BASE_URL}/api/health" \
  --cert "${CLIENT_CERT}" \
  --key "${CLIENT_KEY}" \
  --http1.1 \
  --max-time 10)

echo "$SECOND_HANDSHAKE"

echo ""
echo "如果第二次握手时间明显缩短，说明 TLS Session Resumption 生效"

echo ""

# -----------------------------------------------------------------------------
# 测试 5: WebSocket 连接测试（如果存在 WSS 端点）
# -----------------------------------------------------------------------------
echo "测试 5: WSS 连接测试"
echo "----------------------------------------------"

WSS_URL="wss://xz.caringfamily.cn/ws/ping"
echo "尝试建立 WSS 连接：$WSS_URL"

# 使用 websocat 或 wscat 测试（如果已安装）
if command -v websocat &> /dev/null; then
    echo "使用 websocat 测试..."
    timeout 5 websocat -v "$WSS_URL" --cert "${CLIENT_CERT}" --key "${CLIENT_KEY}" 2>&1 || true
elif command -v wscat &> /dev/null; then
    echo "使用 wscat 测试..."
    timeout 5 wscat -c "$WSS_URL" 2>&1 || true
else
    echo "⚠️  未安装 websocat 或 wscat，跳过 WSS 详细测试"
    echo "提示：安装 websocat: brew install websocat"
fi

echo ""

# -----------------------------------------------------------------------------
# 测试 6: 并发连接测试 (HTTP/1.1)
# -----------------------------------------------------------------------------
echo "测试 6: 并发连接压力测试 (HTTP/1.1)"
echo "----------------------------------------------"
echo "发起 10 个并发请求..."

START_TIME=$(date +%s%N)

for i in {1..10}; do
    curl -s -o /dev/null -X GET "${BASE_URL}/api/health" \
      --cert "${CLIENT_CERT}" \
      --key "${CLIENT_KEY}" \
      --http1.1 \
      --max-time 10 &
done

wait

END_TIME=$(date +%s%N)
TOTAL_ELAPSED=$(( (END_TIME - START_TIME) / 1000000 ))

echo "10 个并发请求总耗时：${TOTAL_ELAPSED}ms"
AVG_CONCURRENT=$((TOTAL_ELAPSED / 10))
echo "平均每个请求耗时：${AVG_CONCURRENT}ms"

if [ $AVG_CONCURRENT -lt 50 ]; then
    echo "✅ 并发性能优秀（连接池可能已优化）"
elif [ $AVG_CONCURRENT -lt 150 ]; then
    echo "⚠️  并发性能一般"
else
    echo "❌ 并发性能较差（可能需要优化连接池配置）"
fi

echo ""

# -----------------------------------------------------------------------------
# 总结
# -----------------------------------------------------------------------------
echo "=============================================="
echo "测试完成！优化建议 (HTTP/1.1 场景):"
echo "=============================================="
echo ""
echo "当前配置分析:"
echo "- ESP32 使用 HTTP/1.1，依赖 Connection: keep-alive 实现连接复用"
echo "- HTTP/1.1 的 keepalive 需要显式配置才能生效"
echo ""
echo "如果发现连接未复用或 TLS 握手成本高，可以在 Higress 中添加以下配置："
echo ""
echo "1. 在 values.yaml gateway.env 中添加:"
echo "   UPSTREAM_KEEPALIVE_IDLE_TIMEOUT: \"300\""
echo "   # 设置空闲连接超时为 300 秒"
echo ""
echo "2. 如果需要更细粒度控制，可以添加 Ingress 注解:"
echo "   annotations:"
echo "     higress.io/upstream-keepalive-requests: \"100\""
echo "     higress.io/upstream-keepalive-timeout: \"60\""
echo ""
echo "3. 对于 mTLS 场景，还可以优化 TLS 会话缓存:"
echo "   SSL_SESSION_CACHE_SIZE: \"10m\""
echo ""
echo "注意：如果响应头中没有 'Connection: keep-alive'，说明网关可能没有返回该头部，"
echo "但这不代表连接没有被复用。Envoy 默认会管理连接池。"
echo ""
