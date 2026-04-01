#!/bin/bash

# =============================================================================
# Higress Dubbo Triple HTTPS + mTLS 接口测试脚本
# 测试 GreeterServiceHttpExport.greet2 接口 (HTTPS + 客户端证书认证)
# =============================================================================

set -e

BASE_URL="https://api.caringfamily.cn:30443"
SERVICE_PATH="/dapi/com.pocrd.dubbo_demo.api.GreeterServiceHttpExport"
METHOD="greet2"

# 证书路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CERT_DIR="${PROJECT_ROOT}/certs/files/bagua"
CA_CERT="${CERT_DIR}/bagua.crt"
CLIENT_CERT="${CERT_DIR}/testFactory/devices/device001/device001-fullchain.crt"
CLIENT_KEY="${CERT_DIR}/testFactory/devices/device001/device001.key"

echo "=============================================="
echo "Higress Dubbo Triple HTTPS + mTLS 接口测试"
echo "=============================================="
echo ""

# 检查证书文件是否存在
if [[ ! -f "$CA_CERT" ]]; then
    echo "❌ 错误：CA 证书不存在：$CA_CERT"
    exit 1
fi

if [[ ! -f "$CLIENT_CERT" ]]; then
    echo "❌ 错误：客户端证书不存在：$CLIENT_CERT"
    exit 1
fi

if [[ ! -f "$CLIENT_KEY" ]]; then
    echo "❌ 错误：客户端私钥不存在：$CLIENT_KEY"
    exit 1
fi

echo "证书配置:"
echo "  CA 证书：$CA_CERT"
echo "  客户端证书：$CLIENT_CERT"
echo ""

# -----------------------------------------------------------------------------
# 测试 1: HTTPS + mTLS + HTTP/2 + JSON 访问 greet2 接口
# -----------------------------------------------------------------------------
echo "测试 1: HTTPS + mTLS + HTTP/2 + JSON 请求 greet2 接口"
echo "----------------------------------------------"
echo "请求: POST ${BASE_URL}${SERVICE_PATH}/${METHOD}"
echo "参数: name1=张三, name2=李四"
echo ""

REQUEST_BODY='{"name1":"张三","name2":"李四"}'

echo "请求 Body:"
echo "$REQUEST_BODY"
echo ""

RESPONSE=$(curl -s --max-time 10 --http2 -X POST \
  "${BASE_URL}${SERVICE_PATH}/${METHOD}" \
  -H "Content-Type: application/json" \
  -d "$REQUEST_BODY" \
  --resolve "api.caringfamily.cn:30443:127.0.0.1" \
  --cacert "$CA_CERT" \
  --cert "$CLIENT_CERT" \
  --key "$CLIENT_KEY" 2>&1) || {
    echo "❌ 请求失败: $RESPONSE"
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
