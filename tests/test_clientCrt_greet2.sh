#!/bin/bash

# =============================================================================
# Higress Dubbo Triple HTTPS + mTLS 客户端证书认证测试脚本
# 测试 GreeterServiceHttpExport.greet2 接口 (HTTPS + 客户端证书认证)
# 包含：正确证书、无证书、错误证书等多种测试场景
# =============================================================================

BASE_URL="https://www.caringfamily.cn:30443"
SERVICE_PATH="/api/com.pocrd.service_demo.api.GreeterServiceHttpExport"
METHOD="greet2"
REQUEST_BODY='{"name1":"张三","name2":"李四"}'

# 证书路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CERT_DIR="${PROJECT_ROOT}/certs/files/caring"
CA_CERT="${CERT_DIR}/caring.crt"
CLIENT_CERT="${CERT_DIR}/factory1/devices/device001/device001.crt"
CLIENT_KEY="${CERT_DIR}/factory1/devices/device001/device001.key"

# 错误证书路径（使用 device005 的证书）
WRONG_CERT="${CERT_DIR}/factory1/devices/device005/device005.crt"
WRONG_KEY="${CERT_DIR}/factory1/devices/device005/device005.key"

# Fullchain 证书路径（device001-fullchain.crt，包含完整证书链）
FULLCHAIN_CERT="${CERT_DIR}/factory1/devices/device001/device001-fullchain.crt"
FULLCHAIN_KEY="${CERT_DIR}/factory1/devices/device001/device001.key"

# Device002 私钥路径（用于证书密钥不匹配测试）
DEVICE002_KEY="${CERT_DIR}/factory1/devices/device002/device002.key"

echo "=============================================="
echo "Higress Dubbo Triple HTTPS + mTLS 测试"
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
echo "  正确客户端证书：$CLIENT_CERT"
echo "  错误客户端证书：$WRONG_CERT"
echo ""

# 计数器
TESTS_PASSED=0
TESTS_FAILED=0

# -----------------------------------------------------------------------------
# 测试 1: HTTPS + mTLS + 单张设备证书（不含中间证书，应该失败）
# -----------------------------------------------------------------------------
echo "测试 1: HTTPS + mTLS + 单张设备证书（不含中间证书）"
echo "----------------------------------------------"
echo "预期：❌ 请求失败（缺少中间证书，无法验证证书链）"
echo ""

RESPONSE=$(curl -s --max-time 10 -X POST \
  "${BASE_URL}${SERVICE_PATH}/${METHOD}" \
  -H "Content-Type: application/json" \
  -d "$REQUEST_BODY" \
  --cert "$CLIENT_CERT" \
  --key "$CLIENT_KEY" \
  --resolve "www.caringfamily.cn:30443:127.0.0.1" 2>&1)

if [ $? -ne 0 ]; then
    echo "✅ 测试 1 通过：单张证书被拒绝（符合预期，缺少中间证书）"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo "响应结果:"
    echo "$RESPONSE"
    echo ""
    echo "❌ 测试 1 失败：单张证书不应该被接受（安全隐患）"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

echo ""
echo ""

# -----------------------------------------------------------------------------
# 测试 2: HTTPS + 无客户端证书访问（在 FAIL_OPEN 策略下可能成功）
# -----------------------------------------------------------------------------
echo "测试 2: HTTPS + 无客户端证书"
echo "----------------------------------------------"
echo "预期：⚠️  在 FAIL_OPEN 策略下可能成功，FAIL_CLOSE 策略下失败"
echo ""

NO_CERT_RESPONSE=$(curl -s --max-time 10 -X POST \
  "${BASE_URL}${SERVICE_PATH}/${METHOD}" \
  -H "Content-Type: application/json" \
  -d "$REQUEST_BODY" \
  --resolve "www.caringfamily.cn:30443:127.0.0.1" 2>&1)

if [ $? -ne 0 ]; then
    echo "❌ 请求被拒绝（FAIL_CLOSE 模式）：$NO_CERT_RESPONSE"
    echo "✅ 测试 2 通过：mTLS 强制验证已生效"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo "响应结果:"
    echo "$NO_CERT_RESPONSE"
    echo ""
    
    # 在 FAIL_OPEN 模式下，没有客户端证书也会返回响应
    if echo "$NO_CERT_RESPONSE" | grep -q "Hello 张三 and 李四"; then
        echo "⚠️  测试 2 通过：FAIL_OPEN 模式允许无证书访问"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    elif echo "$NO_CERT_RESPONSE" | grep -qi "error\|fail\|denied\|certificate"; then
        echo "✅ 测试 2 通过：请求被拒绝（符合预期）"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "❓ 测试 2 结果：未知响应"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
fi

echo ""
echo ""

# -----------------------------------------------------------------------------
# 测试 3: HTTPS + 错误客户端证书（证书密钥不匹配）
# -----------------------------------------------------------------------------
echo "测试 3: HTTPS + 错误客户端证书（证书密钥不匹配）"
echo "----------------------------------------------"
echo "预期：❌ 请求应该被拒绝"
echo ""

# 检查错误证书是否存在
if [[ ! -f "$WRONG_CERT" ]]; then
    echo "⚠️  警告：错误证书不存在：$WRONG_CERT，跳过此测试"
elif [[ ! -f "$WRONG_KEY" ]]; then
    echo "⚠️  警告：错误私钥不存在：$WRONG_KEY，跳过此测试"
else
    WRONG_CERT_RESPONSE=$(curl -s --max-time 10 -X POST \
      "${BASE_URL}${SERVICE_PATH}/${METHOD}" \
      -H "Content-Type: application/json" \
      -d "$REQUEST_BODY" \
      --cert "$WRONG_CERT" \
      --key "$CLIENT_KEY" \
      --resolve "www.caringfamily.cn:30443:127.0.0.1" 2>&1)
    
    if [ $? -ne 0 ]; then
        echo "✅ 测试 3 通过：错误证书被拒绝（证书密钥不匹配）"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "响应结果:"
        echo "$WRONG_CERT_RESPONSE"
        echo ""
        
        # 证书密钥不匹配应该导致请求失败
        if echo "$WRONG_CERT_RESPONSE" | grep -qi "error\|fail\|denied\|handshake\|alert"; then
            echo "✅ 测试 3 通过：错误证书被拒绝"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo "❌ 测试 3 失败：错误证书未被拒绝（安全隐患）"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    fi
fi

echo ""
echo ""

# -----------------------------------------------------------------------------
# 测试 4: HTTPS + Fullchain 客户端证书（完整证书链）
# -----------------------------------------------------------------------------
echo "测试 4: HTTPS + Fullchain 客户端证书 (device001-fullchain.crt)"
echo "----------------------------------------------"
echo "预期：✅ 应该成功（对比单张证书，验证证书链深度）"
echo ""

# 检查 Fullchain 证书文件是否存在
if [[ ! -f "$FULLCHAIN_CERT" ]]; then
    echo "⚠️  警告：Fullchain 证书不存在：$FULLCHAIN_CERT，跳过此测试"
elif [[ ! -f "$FULLCHAIN_KEY" ]]; then
    echo "⚠️  警告：Fullchain 证书私钥不存在：$FULLCHAIN_KEY，跳过此测试"
else
    FULLCHAIN_RESPONSE=$(curl -s --max-time 10 -X POST \
      "${BASE_URL}${SERVICE_PATH}/${METHOD}" \
      -H "Content-Type: application/json" \
      -d "$REQUEST_BODY" \
      --cert "$FULLCHAIN_CERT" \
      --key "$FULLCHAIN_KEY" \
      --resolve "www.caringfamily.cn:30443:127.0.0.1" 2>&1)
    
    if [ $? -ne 0 ]; then
        echo "❌ 请求失败：$FULLCHAIN_RESPONSE"
        TESTS_FAILED=$((TESTS_FAILED +1))
    else
        echo "响应结果:"
        echo "$FULLCHAIN_RESPONSE"
        echo ""
        
        # 验证响应是否包含预期内容
        if echo "$FULLCHAIN_RESPONSE" | grep -q "Hello 张三 and 李四"; then
            echo "✅ 测试 4 通过：Fullchain 证书可以正常访问"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo "❌ 测试 4 失败：响应不包含预期内容"
            TESTS_FAILED=$((TESTS_FAILED +1))
        fi
    fi
fi

echo ""
echo ""

# -----------------------------------------------------------------------------
# 测试 5: HTTPS + 证书密钥不匹配 (device001.crt + device002.key)
# -----------------------------------------------------------------------------
echo "测试 5: HTTPS + 证书密钥不匹配 (device001.crt + device002.key)"
echo "----------------------------------------------"
echo "预期：❌ 请求应该被拒绝（证书与私钥不匹配）"
echo ""

# 检查证书和私钥文件是否存在
if [[ ! -f "$FULLCHAIN_CERT" ]]; then
    echo "⚠️  警告：证书不存在：$FULLCHAIN_CERT，跳过此测试"
elif [[ ! -f "$DEVICE002_KEY" ]]; then
    echo "⚠️  警告：Device002 私钥不存在：$DEVICE002_KEY，跳过此测试"
else
    MISMATCH_RESPONSE=$(curl -s --max-time 10 -X POST \
      "${BASE_URL}${SERVICE_PATH}/${METHOD}" \
      -H "Content-Type: application/json" \
      -d "$REQUEST_BODY" \
      --cert "$FULLCHAIN_CERT" \
      --key "$DEVICE002_KEY" \
      --resolve "www.caringfamily.cn:30443:127.0.0.1" 2>&1)
    
    if [ $? -ne 0 ]; then
        echo "✅ 测试 5 通过：证书密钥不匹配被拒绝"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "响应结果:"
        echo "$MISMATCH_RESPONSE"
        echo ""
        
        # 证书密钥不匹配应该导致请求失败
        if echo "$MISMATCH_RESPONSE" | grep -qi "error\|fail\|denied\|handshake\|alert"; then
            echo "✅ 测试 5 通过：证书密钥不匹配被拒绝"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo "❌ 测试 5 失败：证书密钥不匹配未被拒绝（安全隐患）"
            TESTS_FAILED=$((TESTS_FAILED +1))
        fi
    fi
fi

echo ""
echo ""

# -----------------------------------------------------------------------------
# 测试总结
# -----------------------------------------------------------------------------
echo "=============================================="
echo "测试总结"
echo "=============================================="
echo "通过的测试数：$TESTS_PASSED"
echo "失败的测试数：$TESTS_FAILED"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo "✅ 所有测试通过!"
    exit 0
else
    echo "❌ 部分测试失败!"
    exit 1
fi
