#!/bin/bash
# =============================================================================
# 创建设备证书（由指定服务器证书签发）
# 用法: ./createDeviceCert.sh <CA名称> <服务器名称> <设备ID或数量>
# 示例: 
#   ./createDeviceCert.sh myca server1 device-001    # 单个设备
#   ./createDeviceCert.sh myca server1 10            # 批量生成10个设备
# =============================================================================

set -e

# 检查参数
if [ $# -lt 3 ]; then
    echo "错误: 参数不足"
    echo "用法: $0 <CA名称> <服务器名称> <设备ID或数量>"
    echo "示例: $0 myca server1 device-001"
    echo "        $0 myca server1 10"
    exit 1
fi

CA_NAME="$1"
SERVER_NAME="$2"
THIRD_PARAM="$3"

CERT_DIR="$(cd "$(dirname "$0")" && pwd)"
CA_DIR="${CERT_DIR}/files/${CA_NAME}"
SERVER_DIR="${CA_DIR}/${SERVER_NAME}"
DEVICES_DIR="${SERVER_DIR}/devices"

DAYS=3650
# 使用 ECDSA P-256 椭圆曲线算法
EC_CURVE="prime256v1"

# 检查 CA 证书是否存在
CA_CERT_PATH="${CA_DIR}/${CA_NAME}.crt"
CA_KEY_PATH="${CA_DIR}/${CA_NAME}.key"

if [ ! -f "${CA_CERT_PATH}" ]; then
    echo "错误: CA 证书文件不存在: ${CA_CERT_PATH}"
    exit 1
fi

if [ ! -f "${CA_KEY_PATH}" ]; then
    echo "错误: CA 私钥文件不存在: ${CA_KEY_PATH}"
    exit 1
fi

# 检查服务器证书是否存在
SERVER_CERT_PATH="${SERVER_DIR}/${SERVER_NAME}.crt"
SERVER_KEY_PATH="${SERVER_DIR}/${SERVER_NAME}.key"

if [ ! -f "${SERVER_CERT_PATH}" ]; then
    echo "错误: 服务器证书文件不存在: ${SERVER_CERT_PATH}"
    exit 1
fi

if [ ! -f "${SERVER_KEY_PATH}" ]; then
    echo "错误: 服务器私钥文件不存在: ${SERVER_KEY_PATH}"
    exit 1
fi

# 创建设备证书的函数
create_device_cert() {
    local DEVICE_ID="$1"
    local DEVICE_DIR="${DEVICES_DIR}/${DEVICE_ID}"
    
    echo "----------------------------------------------"
    echo "创建设备: ${DEVICE_ID}"
    
    # 创建设备证书目录
    mkdir -p "${DEVICE_DIR}"
    
    # 文件名包含设备编号，如 device001.key, device001.crt
    local DEVICE_KEY="${DEVICE_DIR}/${DEVICE_ID}.key"
    local DEVICE_CSR="${DEVICE_DIR}/${DEVICE_ID}.csr"
    local DEVICE_CERT="${DEVICE_DIR}/${DEVICE_ID}.crt"
    local DEVICE_FULLCHAIN="${DEVICE_DIR}/${DEVICE_ID}-fullchain.crt"
    
    # 证书信息
    local DEVICE_SUBJECT="/C=CN/ST=Shanghai/L=Shanghai/O=${CA_NAME}/OU=${SERVER_NAME}/CN=${DEVICE_ID}"
    
    # 生成设备私钥（ECDSA）
    openssl ecparam -genkey -name ${EC_CURVE} -out "${DEVICE_KEY}" 2>/dev/null
    
    # 生成设备证书请求
    openssl req -new -key "${DEVICE_KEY}" -out "${DEVICE_CSR}" -subj "${DEVICE_SUBJECT}" 2>/dev/null
    
    # 使用 CA 签发设备证书
    openssl x509 -req -in "${DEVICE_CSR}" -CA "${CA_CERT_PATH}" -CAkey "${CA_KEY_PATH}" \
        -CAcreateserial -out "${DEVICE_CERT}" -days ${DAYS} 2>/dev/null
    
    # 生成设备完整证书链（设备证书 + 服务器证书 + CA证书）
    cat "${DEVICE_CERT}" "${SERVER_CERT_PATH}" "${CA_CERT_PATH}" > "${DEVICE_FULLCHAIN}"
    
    # 清理临时文件
    rm -f "${DEVICE_CSR}"
    
    # 设置权限
    chmod 600 "${DEVICE_KEY}"
    chmod 644 "${DEVICE_CERT}" "${DEVICE_FULLCHAIN}"
    
    echo "  ✓ 完成: ${DEVICE_DIR}"
}

# 判断第三个参数是纯数字（批量生成）还是设备ID（单个生成）
if [[ "${THIRD_PARAM}" =~ ^[0-9]+$ ]]; then
    # 批量生成模式
    COUNT="${THIRD_PARAM}"
    
    # 查找当前最大的设备编号
    MAX_NUM=0
    if [ -d "${DEVICES_DIR}" ]; then
        for dir in "${DEVICES_DIR}"/device*; do
            if [ -d "${dir}" ]; then
                dir_name=$(basename "${dir}")
                # 提取数字部分
                num=$(echo "${dir_name}" | grep -o '[0-9]*' | tail -1)
                if [ -n "${num}" ] && [ "${num}" -gt "${MAX_NUM}" ]; then
                    MAX_NUM="${num}"
                fi
            fi
        done
    fi
    
    echo "=============================================="
    echo "批量创建设备证书"
    echo "当前最大设备编号: ${MAX_NUM}"
    echo "将生成设备数量: ${COUNT}"
    echo "=============================================="
    echo ""
    
    # 批量生成设备证书
    for ((i=1; i<=COUNT; i++)); do
        NEXT_NUM=$((MAX_NUM + i))
        # 格式化为 deviceXXX 格式
        DEVICE_ID=$(printf "device%03d" ${NEXT_NUM})
        create_device_cert "${DEVICE_ID}"
    done
    
    # 清理 CA 序列号文件
    rm -f "${CA_DIR}/${CA_NAME}.srl"
    
    echo ""
    echo "=============================================="
    echo "批量创建完成！共生成 ${COUNT} 个设备证书"
    echo "=============================================="
else
    # 单个设备模式
    DEVICE_ID="${THIRD_PARAM}"
    create_device_cert "${DEVICE_ID}"
    
    # 清理 CA 序列号文件
    rm -f "${CA_DIR}/${CA_NAME}.srl"
fi
