#!/bin/bash

# =============================================================================
# Higress Dubbo Triple HTTPS + mTLS 客户端证书认证测试脚本（简化版）
# 测试 GreeterServiceHttpExport.greet2 接口 (HTTPS + 客户端证书认证)
# 仅包含一个正常用例：使用 Fullchain 客户端证书进行 mTLS 认证
# =============================================================================

set -e

BASE_URL="https://api.caringfamily.cn:30443"
SERVICE_PATH="/dapi/com.pocrd.service_demo.api.GreeterServiceHttpExport"
METHOD="greet2"
REQUEST_BODY='{"name1":"张三","name2":"李四"}'

# 证书路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CERT_DIR="${PROJECT_ROOT}/certs/files/caring"

# 使用 device001 的 fullchain 证书（包含完整证书链）
CA_CERT="${CERT_DIR}/caring.crt"
CLIENT_CERT="${CERT_DIR}/factory1/devices/device001/device001-fullchain.crt"
CLIENT_KEY="${CERT_DIR}/factory1/devices/device001/device001.key"

# 测试配置
MAX_TIME=10

echo "=============================================="
echo "Higress Dubbo Triple HTTPS + mTLS 测试"
echo "=============================================="
echo ""

echo "证书配置:"
echo "  CA 证书：$CA_CERT"
echo "  客户端证书：$CLIENT_CERT"
echo "  客户端私钥：$CLIENT_KEY"
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

# -----------------------------------------------------------------------------
# 测试：使用 Fullchain 客户端证书访问 greet2 接口
# -----------------------------------------------------------------------------
echo "测试：HTTPS + mTLS (Fullchain 客户端证书)"
echo "----------------------------------------------"
echo "预期：✅ 应该成功（验证完整证书链）"
echo ""

echo "请求：POST ${BASE_URL}${SERVICE_PATH}/${METHOD}"
echo "参数：name1=张三，name2=李四"
echo ""

RESPONSE=$(curl -s --max-time $MAX_TIME -X POST \
  "${BASE_URL}${SERVICE_PATH}/${METHOD}" \
  -H "Content-Type: application/json" \
  -d "$REQUEST_BODY" \
  --cert "$CLIENT_CERT" \
  --key "$CLIENT_KEY" \
  --resolve "api.caringfamily.cn:30443:127.0.0.1" 2>&1)
CURL_EXIT=$?

echo "curl 退出码：$CURL_EXIT"
echo "响应结果:"
echo "$RESPONSE"
echo ""

# 验证响应是否成功
if [ $CURL_EXIT -eq 0 ] && echo "$RESPONSE" | grep -q "Hello 张三 and 李四"; then
    echo "✅ 测试通过：mTLS 认证成功，响应包含预期内容"
    echo ""
    echo "=============================================="
    echo "测试完成!"
    echo "=============================================="
    exit 0
else
    echo "❌ 测试失败：mTLS 认证失败或响应异常"
    echo "curl 退出码：$CURL_EXIT"
    echo ""
    echo "=============================================="
    echo "调试信息:"
    echo "  请检查以下配置:"
    echo "  1. Higress Ingress 是否正确配置 mTLS"
    echo "  2. 客户端证书是否由受信任的 CA 签发"
    echo "  3. 证书链是否完整 (使用 fullchain 证书)"
    echo "  4. 证书与私钥是否匹配"
    echo "=============================================="
    exit 1
fi
