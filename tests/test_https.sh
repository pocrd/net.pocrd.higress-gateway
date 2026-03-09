#!/bin/bash

# =============================================================================
# Higress HTTPS 接口测试脚本 (仅 HTTPS，不验证客户端证书)
# 测试 GreeterServiceHttpExport.greet2 接口
# =============================================================================

set -e

# 脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 项目根目录
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Higress 地址 (HTTPS)
BASE_URL="https://localhost"
SERVICE_PATH="/api/com.pocrd.service_demo.api.GreeterServiceHttpExport"
METHOD="greet2"

echo "=============================================="
echo "Higress Dubbo Triple 接口测试 (仅 HTTPS)"
echo "=============================================="
echo ""

# -----------------------------------------------------------------------------
# 测试 1: HTTPS + HTTP/2 访问 greet2 接口 (不携带客户端证书)
# -----------------------------------------------------------------------------
echo "测试 1: HTTPS + HTTP/2 请求 greet2 接口"
echo "----------------------------------------------"
echo "请求: POST ${BASE_URL}${SERVICE_PATH}/${METHOD}"
echo "参数: name1=张三, name2=李四"
echo ""

REQUEST_BODY='{"name1":"张三","name2":"李四"}'

echo "请求 Body:"
echo "$REQUEST_BODY"
echo ""

# 发送请求 (HTTPS，不携带客户端证书)
# --insecure: 跳过服务器证书验证 (测试环境使用自签名证书)
# --http2: 强制使用 HTTP/2
RESPONSE=$(curl -s --max-time 10 -X POST \
  "${BASE_URL}${SERVICE_PATH}/${METHOD}" \
  --http2 \
  --insecure \
  -H "Content-Type: application/json" \
  -d "$REQUEST_BODY" 2>&1) || {
    echo "❌ 请求失败:"
    echo "$RESPONSE"
    exit 1
}

echo "响应结果:"
echo "$RESPONSE"
echo ""

# 验证响应是否包含预期内容
if echo "$RESPONSE" | grep -q "Hello 张三 and 李四"; then
    echo "✅ 测试通过: 响应包含预期内容"
else
    echo "❌ 测试失败: 响应不包含预期内容"
    exit 1
fi

echo ""
echo "=============================================="
echo "所有测试通过!"
echo "=============================================="
