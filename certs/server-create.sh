set -e

# 检查参数
if [ $# -lt 2 ]; then
    echo "错误: 参数不足"
    echo "用法: $0 <CA名称> <服务器名称>"
    echo "示例: $0 caring server1"
    exit 1
fi

CA_NAME="$1"
SERVER_NAME="$2"

CERT_DIR="$(cd "$(dirname "$0")" && pwd)"
CA_DIR="${CERT_DIR}/files/${CA_NAME}"

DAYS=365
# 使用 ECDSA P-256 椭圆曲线算法
EC_CURVE="prime256v1"

echo "=============================================="
echo "创建服务器证书: ${SERVER_NAME}"
echo "=============================================="
echo ""

# CA 证书和密钥路径
CA_CERT_PATH="${CA_DIR}/${CA_NAME}.crt"
CA_KEY_PATH="${CA_DIR}/${CA_NAME}.key"

# 检查 CA 证书文件是否存在
if [ ! -f "${CA_CERT_PATH}" ]; then
    echo "错误: CA 证书文件不存在: ${CA_CERT_PATH}"
    exit 1
fi

if [ ! -f "${CA_KEY_PATH}" ]; then
    echo "错误: CA 私钥文件不存在: ${CA_KEY_PATH}"
    exit 1
fi

# 创建服务器证书目录（放在 CA 目录下）
SERVER_DIR="${CA_DIR}/${SERVER_NAME}"
mkdir -p "${SERVER_DIR}"

SERVER_KEY="${SERVER_DIR}/${SERVER_NAME}.key"
SERVER_CSR="${SERVER_DIR}/${SERVER_NAME}.csr"
SERVER_CERT="${SERVER_DIR}/${SERVER_NAME}.crt"

# 证书信息
SERVER_SUBJECT="/C=CN/ST=Shanghai/L=Shanghai/O=${CA_NAME}/OU=${SERVER_NAME}/CN=${SERVER_NAME}"

# 生成服务器私钥（ECDSA）
echo "[1/3] 生成服务器私钥 (ECDSA P-256)..."
openssl ecparam -genkey -name ${EC_CURVE} -out "${SERVER_KEY}"

# 生成服务器证书请求
echo "[2/3] 生成服务器证书请求..."
openssl req -new -key "${SERVER_KEY}" -out "${SERVER_CSR}" -subj "${SERVER_SUBJECT}"

# 使用 CA 签发服务器证书
echo "[3/3] 使用 CA 签发服务器证书..."
openssl x509 -req -in "${SERVER_CSR}" -CA "${CA_CERT_PATH}" -CAkey "${CA_KEY_PATH}" \
    -CAcreateserial -out "${SERVER_CERT}" -days ${DAYS}

# 清理临时文件
rm -f "${SERVER_CSR}" "${CA_DIR}/${CA_NAME}.srl"

# 设置权限
chmod 600 "${SERVER_KEY}"
chmod 644 "${SERVER_CERT}"

echo ""
echo "=============================================="
echo "服务器证书创建完成！"
echo "=============================================="
echo ""
echo "服务器名称: ${SERVER_NAME}"
echo "输出目录: ${SERVER_DIR}"
echo "签发 CA: ${CA_CERT_PATH}"
echo ""
echo "文件列表:"
echo "  私钥: ${SERVER_KEY}"
echo "  证书: ${SERVER_CERT}"
echo ""
echo "有效期: ${DAYS} 天"
