#!/bin/bash
# =============================================================================
# 创建工厂/中间 CA 证书（由根 CA 签发，带有 CA 扩展）
# 用法: ./factory-create.sh <CA名称> <工厂名称>
# 示例: ./factory-create.sh caring factory1
# =============================================================================

set -e

# 检查参数
if [ $# -lt 2 ]; then
    echo "错误: 参数不足"
    echo "用法: $0 <CA名称> <工厂名称>"
    echo "示例: $0 caring factory1"
    exit 1
fi

CA_NAME="$1"
FACTORY_NAME="$2"

CERT_DIR="$(cd "$(dirname "$0")" && pwd)"
CA_DIR="${CERT_DIR}/files/${CA_NAME}"
FACTORY_DIR="${CA_DIR}/${FACTORY_NAME}"

DAYS=5475
# 使用 ECDSA P-256 椭圆曲线算法
EC_CURVE="prime256v1"

echo "=============================================="
echo "创建工厂/中间 CA 证书: ${FACTORY_NAME}"
echo "根 CA: ${CA_NAME}"
echo "=============================================="
echo ""

# 检查根 CA 证书是否存在
CA_CERT_PATH="${CA_DIR}/${CA_NAME}.crt"
CA_KEY_PATH="${CA_DIR}/${CA_NAME}.key"

if [ ! -f "${CA_CERT_PATH}" ]; then
    echo "错误: 根 CA 证书文件不存在: ${CA_CERT_PATH}"
    exit 1
fi

if [ ! -f "${CA_KEY_PATH}" ]; then
    echo "错误: 根 CA 私钥文件不存在: ${CA_KEY_PATH}"
    exit 1
fi

# 创建工厂目录
mkdir -p "${FACTORY_DIR}"

FACTORY_KEY="${FACTORY_DIR}/${FACTORY_NAME}.key"
FACTORY_CSR="${FACTORY_DIR}/${FACTORY_NAME}.csr"
FACTORY_CERT="${FACTORY_DIR}/${FACTORY_NAME}.crt"

# 证书信息
FACTORY_SUBJECT="/C=CN/ST=Shanghai/L=Shanghai/O=${CA_NAME}/OU=${FACTORY_NAME}/CN=${FACTORY_NAME}"

echo "[1/3] 生成工厂私钥 (ECDSA P-256)..."
openssl ecparam -genkey -name ${EC_CURVE} -out "${FACTORY_KEY}" 2>/dev/null

echo "[2/3] 生成证书请求..."
openssl req -new -key "${FACTORY_KEY}" -out "${FACTORY_CSR}" -subj "${FACTORY_SUBJECT}" 2>/dev/null

echo "[3/3] 使用根 CA 签发工厂证书（带 CA 扩展）..."
# 创建包含 CA 扩展的配置文件
CA_EXT_FILE="${FACTORY_DIR}/ca_ext.cnf"
cat > "${CA_EXT_FILE}" << EOF
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF

# 使用根 CA 签发中间证书，并添加 CA 扩展
openssl x509 -req -in "${FACTORY_CSR}" -CA "${CA_CERT_PATH}" -CAkey "${CA_KEY_PATH}" \
    -CAcreateserial -out "${FACTORY_CERT}" -days ${DAYS} \
    -extfile "${CA_EXT_FILE}" 2>/dev/null

# 验证证书是否包含 CA 扩展
echo ""
echo "验证工厂证书 CA 扩展..."
if openssl x509 -in "${FACTORY_CERT}" -text -noout | grep -q "CA:TRUE"; then
    echo "  ✓ 证书包含 CA:TRUE 扩展"
else
    echo "  ✗ 错误: 证书缺少 CA:TRUE 扩展"
    exit 1
fi

# 清理临时文件
rm -f "${FACTORY_CSR}" "${CA_EXT_FILE}"

# 设置权限
chmod 600 "${FACTORY_KEY}"
chmod 644 "${FACTORY_CERT}"

echo ""
echo "=============================================="
echo "工厂/中间 CA 证书创建完成！"
echo "=============================================="
echo ""
echo "工厂名称: ${FACTORY_NAME}"
echo "输出目录: ${FACTORY_DIR}"
echo ""
echo "文件列表:"
echo "  私钥: ${FACTORY_KEY}"
echo "  证书: ${FACTORY_CERT}"
echo ""
echo "有效期: ${DAYS} 天"
echo ""
echo "注意: 此证书可用于签发设备证书"
