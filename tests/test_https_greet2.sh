#!/bin/bash

# =============================================================================
# Higress Dubbo Triple HTTPS 接口测试脚本
# 测试 GreeterServiceHttpExport.greet2 接口 (HTTPS)
# =============================================================================

set -e

BASE_URL="https://www.caringfamily.cn:30443"
SERVICE_PATH="/api/com.pocrd.service_demo.api.GreeterServiceHttpExport"
METHOD="greet2"

echo "=============================================="
echo "Higress Dubbo Triple HTTPS 接口测试"
echo "=============================================="
echo ""

echo "证书配置:"
echo "  使用系统默认 CA (信任 Let's Encrypt)"
echo ""

# -----------------------------------------------------------------------------
# 测试 1: HTTPS + HTTP/2 + JSON 访问 greet2 接口（暂不验证客户端证书）
# -----------------------------------------------------------------------------
echo "测试 1: HTTPS + HTTP/2 + JSON 请求 greet2 接口"
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
  --resolve "www.caringfamily.cn:30443:127.0.0.1" \
  --insecure 2>&1) || {
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
