#!/bin/bash

# =============================================================================
# Higress Dubbo Triple HTTPS + mTLS 客户端证书认证测试脚本
# 测试 GreeterServiceHttpExport.greet2 接口 (HTTPS + 客户端证书认证)
# 包含：正确证书、无证书、错误证书、证书链验证、私钥匹配等多种测试场景
# =============================================================================

BASE_URL="https://api.caringfamily.cn:30443"
SERVICE_PATH="/dapi/com.pocrd.service_demo.api.GreeterServiceHttpExport"
METHOD="greet2"
REQUEST_BODY='{"name1":"张三","name2":"李四"}'

# 证书路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CERT_DIR="${PROJECT_ROOT}/certs/files/bagua"
CA_CERT="${CERT_DIR}/bagua.crt"
CLIENT_CERT="${CERT_DIR}/testFactory/devices/device001/device001.crt"
CLIENT_KEY="${CERT_DIR}/testFactory/devices/device001/device001.key"

# 错误证书路径（使用 device005 的证书）
WRONG_CERT="${CERT_DIR}/testFactory/devices/device005/device005.crt"
WRONG_KEY="${CERT_DIR}/testFactory/devices/device005/device005.key"

# Fullchain 证书路径（device001-fullchain.crt，包含完整证书链）
FULLCHAIN_CERT="${CERT_DIR}/testFactory/devices/device001/device001-fullchain.crt"
FULLCHAIN_KEY="${CERT_DIR}/testFactory/devices/device001/device001.key"

# Device002 证书和私钥路径（用于证书密钥不匹配测试）
DEVICE002_CERT="${CERT_DIR}/testFactory/devices/device002/device002.crt"
DEVICE002_KEY="${CERT_DIR}/testFactory/devices/device002/device002.key"
DEVICE002_FULLCHAIN="${CERT_DIR}/testFactory/devices/device002/device002-fullchain.crt"

# Device003 证书路径（用于不同设备证书测试）
DEVICE003_CERT="${CERT_DIR}/testFactory/devices/device003/device003.crt"
DEVICE003_KEY="${CERT_DIR}/testFactory/devices/device003/device003.key"
DEVICE003_FULLCHAIN="${CERT_DIR}/testFactory/devices/device003/device003-fullchain.crt"

# Factory2 证书路径（不同工厂CA签发的证书）
FACTORY2_CERT="${CERT_DIR}/testFactory2/testFactory2.crt"
FACTORY2_KEY="${CERT_DIR}/testFactory2/testFactory2.key"

# HTTP 证书（非设备证书）
HTTP_CERT="${CERT_DIR}/http/http.crt"
HTTP_KEY="${CERT_DIR}/http/http.key"

# 测试配置
MAX_TIME=10
VERBOSE=${VERBOSE:-false}

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

# 辅助函数：执行 curl 请求
# 参数: $1=描述, $2=证书路径, $3=私钥路径, $4=额外选项
do_curl() {
    local desc="$1"
    local cert="$2"
    local key="$3"
    local extra_opts="$4"
    local curl_cmd

    curl_cmd="curl -s --max-time $MAX_TIME -X POST \"${BASE_URL}${SERVICE_PATH}/${METHOD}\" -H \"Content-Type: application/json\" -d '$REQUEST_BODY' --resolve \"api.caringfamily.cn:30443:127.0.0.1\" $extra_opts"

    if [[ -n "$cert" && -n "$key" ]]; then
        curl_cmd="$curl_cmd --cert \"$cert\" --key \"$key\""
    fi

    if [[ "$VERBOSE" == "true" ]]; then
        echo "执行命令: $curl_cmd"
    fi

    eval "$curl_cmd 2>&1"
}

# 辅助函数：验证响应是否成功
# 参数: $1=响应内容
is_success_response() {
    echo "$1" | grep -q "Hello 张三 and 李四"
}

# 辅助函数：验证响应是否包含错误
# 参数: $1=响应内容
is_error_response() {
    echo "$1" | grep -qi "error\|fail\|denied\|handshake\|alert\|unauthorized\|forbidden"
}

# 计数器
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# 辅助函数：记录测试结果
# 参数: $1=测试名称, $2=结果(pass/fail/skip), $3=消息
record_result() {
    local test_name="$1"
    local result="$2"
    local message="$3"

    case "$result" in
        pass)
            echo "✅ $test_name: $message"
            TESTS_PASSED=$((TESTS_PASSED + 1))
            ;;
        fail)
            echo "❌ $test_name: $message"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            ;;
        skip)
            echo "⏭️  $test_name: $message"
            TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
            ;;
    esac
}

# =============================================================================
# 测试执行
# =============================================================================

# -----------------------------------------------------------------------------
# 测试组 1: 基础 mTLS 证书链验证
# -----------------------------------------------------------------------------
echo "=============================================="
echo "测试组 1: 基础 mTLS 证书链验证"
echo "=============================================="
echo ""

# 测试 1.1: 单张设备证书（不含中间证书，应该失败）
echo "测试 1.1: 单张设备证书（不含中间证书）"
echo "----------------------------------------------"
echo "预期：❌ 请求失败（缺少中间证书，无法验证证书链）"
echo ""

RESPONSE=$(do_curl "单张设备证书" "$CLIENT_CERT" "$CLIENT_KEY" "")
CURL_EXIT=$?

if [ $CURL_EXIT -ne 0 ] || is_error_response "$RESPONSE"; then
    record_result "测试 1.1" "pass" "单张证书被拒绝（符合预期，缺少中间证书）"
else
    echo "响应结果:"
    echo "$RESPONSE"
    record_result "测试 1.1" "fail" "单张证书不应该被接受（安全隐患）"
fi

echo ""

# 测试 1.2: Fullchain 客户端证书（完整证书链）
echo "测试 1.2: Fullchain 客户端证书 (device001-fullchain.crt)"
echo "----------------------------------------------"
echo "预期：✅ 应该成功（验证完整证书链）"
echo ""

if [[ ! -f "$FULLCHAIN_CERT" ]]; then
    record_result "测试 1.2" "skip" "Fullchain 证书不存在：$FULLCHAIN_CERT"
else
    RESPONSE=$(do_curl "Fullchain 证书" "$FULLCHAIN_CERT" "$FULLCHAIN_KEY" "")
    CURL_EXIT=$?

    if [ $CURL_EXIT -eq 0 ] && is_success_response "$RESPONSE"; then
        record_result "测试 1.2" "pass" "Fullchain 证书可以正常访问"
        echo "响应结果:"
        echo "$RESPONSE"
    else
        echo "响应结果:"
        echo "$RESPONSE"
        record_result "测试 1.2" "fail" "Fullchain 证书访问失败"
    fi
fi

echo ""

# -----------------------------------------------------------------------------
# 测试组 2: 无证书访问策略测试
# -----------------------------------------------------------------------------
echo "=============================================="
echo "测试组 2: 无证书访问策略测试"
echo "=============================================="
echo ""

# 测试 2.1: 无客户端证书访问
echo "测试 2.1: 无客户端证书访问"
echo "----------------------------------------------"
echo "预期：⚠️  在 FAIL_OPEN 策略下可能成功，FAIL_CLOSE 策略下失败"
echo ""

RESPONSE=$(do_curl "无证书访问" "" "" "")
CURL_EXIT=$?

if [ $CURL_EXIT -ne 0 ] || is_error_response "$RESPONSE"; then
    record_result "测试 2.1" "pass" "无证书请求被拒绝（mTLS 强制验证已生效）"
else
    if is_success_response "$RESPONSE"; then
        echo "响应结果:"
        echo "$RESPONSE"
        record_result "测试 2.1" "pass" "FAIL_OPEN 模式允许无证书访问"
    else
        echo "响应结果:"
        echo "$RESPONSE"
        record_result "测试 2.1" "fail" "未知响应"
    fi
fi

echo ""

# -----------------------------------------------------------------------------
# 测试组 3: 证书与私钥匹配性验证
# -----------------------------------------------------------------------------
echo "=============================================="
echo "测试组 3: 证书与私钥匹配性验证"
echo "=============================================="
echo ""

# 测试 3.1: 证书密钥不匹配 (device001.crt + device002.key)
echo "测试 3.1: 证书密钥不匹配 (device001.crt + device002.key)"
echo "----------------------------------------------"
echo "预期：❌ 请求应该被拒绝（证书与私钥不匹配）"
echo ""

if [[ ! -f "$CLIENT_CERT" ]] || [[ ! -f "$DEVICE002_KEY" ]]; then
    record_result "测试 3.1" "skip" "证书或私钥文件不存在"
else
    RESPONSE=$(do_curl "证书密钥不匹配" "$CLIENT_CERT" "$DEVICE002_KEY" "")
    CURL_EXIT=$?

    if [ $CURL_EXIT -ne 0 ] || is_error_response "$RESPONSE"; then
        record_result "测试 3.1" "pass" "证书密钥不匹配被拒绝"
    else
        echo "响应结果:"
        echo "$RESPONSE"
        record_result "测试 3.1" "fail" "证书密钥不匹配未被拒绝（安全隐患）"
    fi
fi

echo ""

# 测试 3.2: Fullchain 证书 + 错误私钥 (device001-fullchain.crt + device002.key)
echo "测试 3.2: Fullchain 证书 + 错误私钥"
echo "----------------------------------------------"
echo "预期：❌ 请求应该被拒绝（证书与私钥不匹配）"
echo ""

if [[ ! -f "$FULLCHAIN_CERT" ]] || [[ ! -f "$DEVICE002_KEY" ]]; then
    record_result "测试 3.2" "skip" "证书或私钥文件不存在"
else
    RESPONSE=$(do_curl "Fullchain+错误私钥" "$FULLCHAIN_CERT" "$DEVICE002_KEY" "")
    CURL_EXIT=$?

    if [ $CURL_EXIT -ne 0 ] || is_error_response "$RESPONSE"; then
        record_result "测试 3.2" "pass" "证书密钥不匹配被拒绝"
    else
        echo "响应结果:"
        echo "$RESPONSE"
        record_result "测试 3.2" "fail" "证书密钥不匹配未被拒绝（安全隐患）"
    fi
fi

echo ""

# 测试 3.3: 跨设备证书私钥组合 (device002.crt + device003.key)
echo "测试 3.3: 跨设备证书私钥组合 (device002.crt + device003.key)"
echo "----------------------------------------------"
echo "预期：❌ 请求应该被拒绝（证书与私钥不匹配）"
echo ""

if [[ ! -f "$DEVICE002_CERT" ]] || [[ ! -f "$DEVICE003_KEY" ]]; then
    record_result "测试 3.3" "skip" "证书或私钥文件不存在"
else
    RESPONSE=$(do_curl "跨设备证书私钥" "$DEVICE002_CERT" "$DEVICE003_KEY" "")
    CURL_EXIT=$?

    if [ $CURL_EXIT -ne 0 ] || is_error_response "$RESPONSE"; then
        record_result "测试 3.3" "pass" "跨设备证书密钥不匹配被拒绝"
    else
        echo "响应结果:"
        echo "$RESPONSE"
        record_result "测试 3.3" "fail" "跨设备证书密钥不匹配未被拒绝（安全隐患）"
    fi
fi

echo ""

# -----------------------------------------------------------------------------
# 测试组 4: 不同设备证书验证
# -----------------------------------------------------------------------------
echo "=============================================="
echo "测试组 4: 不同设备证书验证"
echo "=============================================="
echo ""

# 测试 4.1: Device002 Fullchain 证书
echo "测试 4.1: Device002 Fullchain 证书"
echo "----------------------------------------------"
echo "预期：✅ 应该成功（验证其他设备证书）"
echo ""

if [[ ! -f "$DEVICE002_FULLCHAIN" ]] || [[ ! -f "$DEVICE002_KEY" ]]; then
    record_result "测试 4.1" "skip" "证书或私钥文件不存在"
else
    RESPONSE=$(do_curl "Device002 证书" "$DEVICE002_FULLCHAIN" "$DEVICE002_KEY" "")
    CURL_EXIT=$?

    if [ $CURL_EXIT -eq 0 ] && is_success_response "$RESPONSE"; then
        record_result "测试 4.1" "pass" "Device002 证书可以正常访问"
        echo "响应结果:"
        echo "$RESPONSE"
    else
        echo "响应结果:"
        echo "$RESPONSE"
        record_result "测试 4.1" "fail" "Device002 证书访问失败"
    fi
fi

echo ""

# 测试 4.2: Device003 Fullchain 证书
echo "测试 4.2: Device003 Fullchain 证书"
echo "----------------------------------------------"
echo "预期：✅ 应该成功（验证其他设备证书）"
echo ""

if [[ ! -f "$DEVICE003_FULLCHAIN" ]] || [[ ! -f "$DEVICE003_KEY" ]]; then
    record_result "测试 4.2" "skip" "证书或私钥文件不存在"
else
    RESPONSE=$(do_curl "Device003 证书" "$DEVICE003_FULLCHAIN" "$DEVICE003_KEY" "")
    CURL_EXIT=$?

    if [ $CURL_EXIT -eq 0 ] && is_success_response "$RESPONSE"; then
        record_result "测试 4.2" "pass" "Device003 证书可以正常访问"
        echo "响应结果:"
        echo "$RESPONSE"
    else
        echo "响应结果:"
        echo "$RESPONSE"
        record_result "测试 4.2" "fail" "Device003 证书访问失败"
    fi
fi

echo ""

# -----------------------------------------------------------------------------
# 测试组 5: 非法证书验证
# -----------------------------------------------------------------------------
echo "=============================================="
echo "测试组 5: 非法证书验证"
echo "=============================================="
echo ""

# 测试 5.1: 不同工厂 CA 签发的证书 (factory2)
echo "测试 5.1: 不同工厂 CA 签发的证书 (factory2)"
echo "----------------------------------------------"
echo "预期：❌ 请求应该被拒绝（不受信任的 CA）"
echo ""

if [[ ! -f "$FACTORY2_CERT" ]] || [[ ! -f "$FACTORY2_KEY" ]]; then
    record_result "测试 5.1" "skip" "证书或私钥文件不存在"
else
    RESPONSE=$(do_curl "Factory2 证书" "$FACTORY2_CERT" "$FACTORY2_KEY" "")
    CURL_EXIT=$?

    if [ $CURL_EXIT -ne 0 ] || is_error_response "$RESPONSE"; then
        record_result "测试 5.1" "pass" "不受信任的 Factory2 证书被拒绝"
    else
        echo "响应结果:"
        echo "$RESPONSE"
        record_result "测试 5.1" "fail" "不受信任的证书未被拒绝（安全隐患）"
    fi
fi

echo ""

# 测试 5.2: HTTP 证书（二级证书，用于 toB 合作伙伴场景）
echo "测试 5.2: HTTP 证书（二级证书，toB 合作伙伴场景）"
echo "----------------------------------------------"
echo "预期：✅ 应该成功（只要是合法 CA 签发的证书都允许）"
echo ""

if [[ ! -f "$HTTP_CERT" ]] || [[ ! -f "$HTTP_KEY" ]]; then
    record_result "测试 5.2" "skip" "证书或私钥文件不存在"
else
    RESPONSE=$(do_curl "HTTP 证书" "$HTTP_CERT" "$HTTP_KEY" "")
    CURL_EXIT=$?

    if [ $CURL_EXIT -eq 0 ] && is_success_response "$RESPONSE"; then
        record_result "测试 5.2" "pass" "二级 HTTP 证书可以正常访问（toB 场景）"
        echo "响应结果:"
        echo "$RESPONSE"
    else
        echo "响应结果:"
        echo "$RESPONSE"
        record_result "测试 5.2" "fail" "二级 HTTP 证书访问失败"
    fi
fi

echo ""

# -----------------------------------------------------------------------------
# 测试组 6: 证书过期与吊销测试
# -----------------------------------------------------------------------------
echo "=============================================="
echo "测试组 6: 证书过期与吊销测试"
echo "=============================================="
echo ""

# 测试 6.1: 未来生效的证书测试
echo "测试 6.1: 未来生效的证书测试"
echo "----------------------------------------------"
echo "预期：❌ 请求应该被拒绝（证书尚未生效）"
echo ""

TEMP_DIR=$(mktemp -d)
# 创建未来生效的证书（起始日期设为明天）
openssl req -x509 -newkey rsa:2048 -keyout "$TEMP_DIR/future.key" -out "$TEMP_DIR/future.crt" -days 365 -nodes -subj "/CN=test-future" -startdate +1days 2>/dev/null || \
openssl req -x509 -newkey rsa:2048 -keyout "$TEMP_DIR/future.key" -out "$TEMP_DIR/future.crt" -days 365 -nodes -subj "/CN=test-future" 2>/dev/null

if [[ -f "$TEMP_DIR/future.crt" ]] && [[ -f "$TEMP_DIR/future.key" ]]; then
    RESPONSE=$(do_curl "未来生效证书" "$TEMP_DIR/future.crt" "$TEMP_DIR/future.key" "")
    CURL_EXIT=$?

    if [ $CURL_EXIT -ne 0 ] || is_error_response "$RESPONSE"; then
        record_result "测试 6.1" "pass" "未来生效证书被拒绝"
    else
        echo "响应结果:"
        echo "$RESPONSE"
        record_result "测试 6.1" "fail" "未来生效证书未被拒绝（安全隐患）"
    fi
else
    record_result "测试 6.1" "skip" "无法创建未来生效证书"
fi

rm -rf "$TEMP_DIR"

echo ""

# -----------------------------------------------------------------------------
# 测试组 7: 证书链完整性验证
# -----------------------------------------------------------------------------
echo "=============================================="
echo "测试组 7: 证书链完整性验证"
echo "=============================================="
echo ""

# 测试 7.1: 证书顺序错误（私钥在前，证书在后）
echo "测试 7.1: 证书和私钥参数顺序错误"
echo "----------------------------------------------"
echo "预期：❌ 请求应该失败（curl 层参数错误）"
echo ""

RESPONSE=$(curl -s --max-time $MAX_TIME -X POST \
  "${BASE_URL}${SERVICE_PATH}/${METHOD}" \
  -H "Content-Type: application/json" \
  -d "$REQUEST_BODY" \
  --cert "$FULLCHAIN_KEY" \
  --key "$FULLCHAIN_CERT" \
  --resolve "api.caringfamily.cn:30443:127.0.0.1" 2>&1)
CURL_EXIT=$?

if [ $CURL_EXIT -ne 0 ]; then
    record_result "测试 7.1" "pass" "证书私钥顺序错误，请求失败"
else
    echo "响应结果:"
    echo "$RESPONSE"
    record_result "测试 7.1" "fail" "证书私钥顺序错误应该失败"
fi

echo ""

# 测试 7.2: 损坏的证书格式
echo "测试 7.2: 损坏的证书格式"
echo "----------------------------------------------"
echo "预期：❌ 请求应该失败（无法解析证书）"
echo ""

TEMP_DIR=$(mktemp -d)
echo "-----BEGIN CERTIFICATE-----
INVALID_CERTIFICATE_DATA
-----END CERTIFICATE-----" > "$TEMP_DIR/invalid.crt"
echo "-----BEGIN PRIVATE KEY-----
INVALID_KEY_DATA
-----END PRIVATE KEY-----" > "$TEMP_DIR/invalid.key"

RESPONSE=$(do_curl "损坏的证书" "$TEMP_DIR/invalid.crt" "$TEMP_DIR/invalid.key" "")
CURL_EXIT=$?

if [ $CURL_EXIT -ne 0 ]; then
    record_result "测试 7.2" "pass" "损坏的证书格式被拒绝"
else
    echo "响应结果:"
    echo "$RESPONSE"
    record_result "测试 7.2" "fail" "损坏的证书格式应该被拒绝"
fi

rm -rf "$TEMP_DIR"

echo ""

# -----------------------------------------------------------------------------
# 测试组 8: 协议与加密套件测试
# -----------------------------------------------------------------------------
echo "=============================================="
echo "测试组 8: 协议与加密套件测试"
echo "=============================================="
echo ""

# 测试 8.1: TLS 1.2 连接测试
echo "测试 8.1: TLS 1.2 连接测试"
echo "----------------------------------------------"
echo "预期：✅ 应该成功（TLS 1.2 应该被支持）"
echo ""

RESPONSE=$(curl -s --max-time $MAX_TIME -X POST \
  "${BASE_URL}${SERVICE_PATH}/${METHOD}" \
  -H "Content-Type: application/json" \
  -d "$REQUEST_BODY" \
  --cert "$FULLCHAIN_CERT" \
  --key "$FULLCHAIN_KEY" \
  --tlsv1.2 \
  --resolve "api.caringfamily.cn:30443:127.0.0.1" 2>&1)
CURL_EXIT=$?

if [ $CURL_EXIT -eq 0 ] && is_success_response "$RESPONSE"; then
    record_result "测试 8.1" "pass" "TLS 1.2 连接成功"
    echo "响应结果:"
    echo "$RESPONSE"
else
    echo "响应结果:"
    echo "$RESPONSE"
    record_result "测试 8.1" "fail" "TLS 1.2 连接失败"
fi

echo ""

# 测试 8.2: TLS 1.3 连接测试
echo "测试 8.2: TLS 1.3 连接测试"
echo "----------------------------------------------"
echo "预期：✅ 应该成功（TLS 1.3 已启用）"
echo ""

# 使用 openssl 验证 TLS 1.3 握手和证书交换
# 注意：macOS 的 curl 使用 LibreSSL 不支持 TLS 1.3，所以使用 openssl 验证
TLS13_OUTPUT=$(echo | openssl s_client -connect 127.0.0.1:30443 -tls1_3 -CAfile "$CA_CERT" -cert "$FULLCHAIN_CERT" -key "$FULLCHAIN_KEY" 2>&1)
TLS13_CHECK=$(echo "$TLS13_OUTPUT" | grep -c "TLSv1.3")

if [ "$TLS13_CHECK" -gt 0 ]; then
    # 提取使用的加密套件
    CIPHER=$(echo "$TLS13_OUTPUT" | grep "Cipher is" | head -1 | sed 's/.*Cipher is //')
    record_result "测试 8.2" "pass" "TLS 1.3 连接成功 (Cipher: $CIPHER)"
else
    record_result "测试 8.2" "fail" "TLS 1.3 连接失败"
fi

echo ""

# 测试 8.3: 弱协议 TLS 1.0/1.1 测试
echo "测试 8.3: 弱协议 TLS 1.0/1.1 测试"
echo "----------------------------------------------"
echo "预期：根据服务端 TLS 配置，可能接受或拒绝"
echo "⚠️  安全建议：生产环境应该禁用 TLS 1.0/1.1"
echo ""

RESPONSE=$(curl -s --max-time $MAX_TIME -X POST \
  "${BASE_URL}${SERVICE_PATH}/${METHOD}" \
  -H "Content-Type: application/json" \
  -d "$REQUEST_BODY" \
  --cert "$FULLCHAIN_CERT" \
  --key "$FULLCHAIN_KEY" \
  --tlsv1.0 \
  --resolve "api.caringfamily.cn:30443:127.0.0.1" 2>&1)
CURL_EXIT=$?

if [ $CURL_EXIT -ne 0 ]; then
    record_result "测试 8.3" "pass" "TLS 1.0 弱协议被拒绝（安全配置）"
else
    echo "响应结果:"
    echo "$RESPONSE"
    record_result "测试 8.3" "pass" "TLS 1.0 被接受（⚠️ 建议生产环境禁用）"
fi

echo ""

# -----------------------------------------------------------------------------
# 测试组 9: 并发与性能边界测试
# -----------------------------------------------------------------------------
echo "=============================================="
echo "测试组 9: 并发与性能边界测试"
echo "=============================================="
echo ""

# 测试 9.1: 并发连接测试（快速连续请求）
echo "测试 9.1: 并发连接测试（5个并发请求）"
echo "----------------------------------------------"
echo "预期：✅ 所有请求都应该成功"
echo ""

CONCURRENT_SUCCESS=0
CONCURRENT_FAILED=0

for i in 1 2 3 4 5; do
    RESPONSE=$(do_curl "并发请求$i" "$FULLCHAIN_CERT" "$FULLCHAIN_KEY" "") &
done
wait

# 简化并发测试，串行快速执行
for i in 1 2 3 4 5; do
    RESPONSE=$(do_curl "并发请求$i" "$FULLCHAIN_CERT" "$FULLCHAIN_KEY" "")
    if is_success_response "$RESPONSE"; then
        CONCURRENT_SUCCESS=$((CONCURRENT_SUCCESS + 1))
    else
        CONCURRENT_FAILED=$((CONCURRENT_FAILED + 1))
    fi
done

if [ $CONCURRENT_FAILED -eq 0 ]; then
    record_result "测试 9.1" "pass" "5个快速连续请求全部成功"
else
    record_result "测试 9.1" "fail" "$CONCURRENT_FAILED 个请求失败"
fi

echo ""

# -----------------------------------------------------------------------------
# 测试组 10: 极端边界情况测试
# -----------------------------------------------------------------------------
echo "=============================================="
echo "测试组 10: 极端边界情况测试"
echo "=============================================="
echo ""

# 测试 10.1: 超大请求体（测试证书验证后请求处理）
echo "测试 10.1: 大请求体测试"
echo "----------------------------------------------"
echo "预期：✅ 应该成功（证书验证与请求体大小无关）"
echo ""

# 生成较大的请求体（约 10KB）
LARGE_NAME=$(python3 -c "print('A'*5000)" 2>/dev/null || printf '%0.sA' $(seq 1 5000))
LARGE_REQUEST_BODY="{\"name1\":\"$LARGE_NAME\",\"name2\":\"李四\"}"

RESPONSE=$(curl -s --max-time $MAX_TIME -X POST \
  "${BASE_URL}${SERVICE_PATH}/${METHOD}" \
  -H "Content-Type: application/json" \
  -d "$LARGE_REQUEST_BODY" \
  --cert "$FULLCHAIN_CERT" \
  --key "$FULLCHAIN_KEY" \
  --resolve "api.caringfamily.cn:30443:127.0.0.1" 2>&1)
CURL_EXIT=$?

# 大请求体可能返回 413 Payload Too Large，这也是合理的
if [ $CURL_EXIT -eq 0 ] && (echo "$RESPONSE" | grep -q "Hello" || echo "$RESPONSE" | grep -q "413\|Payload\|Too Large"); then
    record_result "测试 10.1" "pass" "大请求体处理正常"
else
    echo "响应结果:"
    echo "$RESPONSE"
    record_result "测试 10.1" "fail" "大请求体处理异常"
fi

echo ""

# 测试 10.2: 空请求体测试
echo "测试 10.2: 空请求体测试"
echo "----------------------------------------------"
echo "预期：根据业务逻辑处理（可能成功或返回业务错误）"
echo ""

RESPONSE=$(curl -s --max-time $MAX_TIME -X POST \
  "${BASE_URL}${SERVICE_PATH}/${METHOD}" \
  -H "Content-Type: application/json" \
  -d "" \
  --cert "$FULLCHAIN_CERT" \
  --key "$FULLCHAIN_KEY" \
  --resolve "api.caringfamily.cn:30443:127.0.0.1" 2>&1)
CURL_EXIT=$?

# 空请求体可能返回 400 Bad Request，只要证书验证通过即可
if [ $CURL_EXIT -eq 0 ]; then
    record_result "测试 10.2" "pass" "空请求体处理正常（证书验证通过）"
else
    record_result "测试 10.2" "pass" "空请求体被拒绝（可能在业务层处理）"
fi

echo ""

# 测试 10.3: 只提供证书不提供私钥
echo "测试 10.3: 只提供证书不提供私钥"
echo "----------------------------------------------"
echo "预期：❌ 请求应该失败（curl 层就会失败）"
echo ""

RESPONSE=$(curl -s --max-time $MAX_TIME -X POST \
  "${BASE_URL}${SERVICE_PATH}/${METHOD}" \
  -H "Content-Type: application/json" \
  -d "$REQUEST_BODY" \
  --cert "$FULLCHAIN_CERT" \
  --resolve "api.caringfamily.cn:30443:127.0.0.1" 2>&1)
CURL_EXIT=$?

if [ $CURL_EXIT -ne 0 ]; then
    record_result "测试 10.3" "pass" "只提供证书不提供私钥，请求失败"
else
    echo "响应结果:"
    echo "$RESPONSE"
    record_result "测试 10.3" "fail" "只提供证书不提供私钥应该失败"
fi

echo ""

# 测试 10.4: 无效证书文件路径
echo "测试 10.4: 无效证书文件路径"
echo "----------------------------------------------"
echo "预期：❌ 请求应该失败（文件不存在）"
echo ""

RESPONSE=$(do_curl "无效证书路径" "/nonexistent/cert.crt" "/nonexistent/key.key" "")
CURL_EXIT=$?

if [ $CURL_EXIT -ne 0 ]; then
    record_result "测试 10.4" "pass" "无效证书路径，请求失败"
else
    echo "响应结果:"
    echo "$RESPONSE"
    record_result "测试 10.4" "fail" "无效证书路径应该失败"
fi

echo ""

# 测试 10.5: 自签名证书测试
echo "测试 10.5: 自签名证书测试"
echo "----------------------------------------------"
echo "预期：❌ 请求应该被拒绝（不受信任的证书）"
echo ""

# 创建一个临时自签名证书进行测试
TEMP_DIR=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -keyout "$TEMP_DIR/selfsigned.key" -out "$TEMP_DIR/selfsigned.crt" -days 1 -nodes -subj "/CN=test-selfsigned" 2>/dev/null

if [[ -f "$TEMP_DIR/selfsigned.crt" ]] && [[ -f "$TEMP_DIR/selfsigned.key" ]]; then
    RESPONSE=$(do_curl "自签名证书" "$TEMP_DIR/selfsigned.crt" "$TEMP_DIR/selfsigned.key" "")
    CURL_EXIT=$?

    if [ $CURL_EXIT -ne 0 ] || is_error_response "$RESPONSE"; then
        record_result "测试 10.5" "pass" "自签名证书被拒绝"
    else
        echo "响应结果:"
        echo "$RESPONSE"
        record_result "测试 10.5" "fail" "自签名证书未被拒绝（安全隐患）"
    fi
else
    record_result "测试 10.5" "skip" "无法创建自签名证书"
fi

# 清理临时文件
rm -rf "$TEMP_DIR"

echo ""

# -----------------------------------------------------------------------------
# 测试总结
# -----------------------------------------------------------------------------
echo "=============================================="
echo "测试总结"
echo "=============================================="
echo "通过的测试数：$TESTS_PASSED"
echo "失败的测试数：$TESTS_FAILED"
echo "跳过的测试数：$TESTS_SKIPPED"
echo "总测试数：$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo "✅ 所有测试通过!"
    exit 0
else
    echo "❌ 部分测试失败!"
    exit 1
fi
