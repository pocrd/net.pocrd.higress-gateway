set -e

# 检查参数
if [ $# -lt 1 ]; then
    echo "错误: 请指定 CA 名称"
    echo "用法: $0 <CA名称>"
    echo "示例: $0 caring"
    exit 1
fi

CA_NAME="$1"
CERT_DIR="$(cd "$(dirname "$0")" && pwd)"
CA_DIR="${CERT_DIR}/files/${CA_NAME}"

DAYS=7300
# 使用 ECDSA P-256 椭圆曲线算法（比 RSA 更快、更安全）
EC_CURVE="prime256v1"

echo "=============================================="
echo "创建 CA 证书: ${CA_NAME}"
echo "=============================================="
echo ""

# 创建 CA 目录
mkdir -p "${CA_DIR}"

CA_KEY="${CA_DIR}/${CA_NAME}.key"
CA_CERT="${CA_DIR}/${CA_NAME}.crt"

# 证书信息
CA_SUBJECT="/C=CN/ST=Shanghai/L=Shanghai/O=${CA_NAME}-CA/OU=CA/CN=${CA_NAME}-Root-CA"

# 生成 CA 私钥（ECDSA）
echo "[1/2] 生成 CA 私钥 (ECDSA P-256)..."
openssl ecparam -genkey -name ${EC_CURVE} -out "${CA_KEY}"

# 生成 CA 证书
echo "[2/2] 生成 CA 证书..."
openssl req -new -x509 -key "${CA_KEY}" -out "${CA_CERT}" -days ${DAYS} -subj "${CA_SUBJECT}"

# 设置权限
chmod 600 "${CA_KEY}"
chmod 644 "${CA_CERT}"

echo ""
echo "=============================================="
echo "CA 证书创建完成！"
echo "=============================================="
echo ""
echo "CA 名称: ${CA_NAME}"
echo "输出目录: ${CA_DIR}"
echo ""
echo "文件列表:"
echo "  私钥: ${CA_KEY}"
echo "  证书: ${CA_CERT}"
echo ""
echo "有效期: ${DAYS} 天"
