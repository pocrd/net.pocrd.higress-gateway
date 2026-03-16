#!/bin/bash

# =================================================================
# 证书检查和同步脚本
# 检查 acme.sh 证书是否存在且在有效期内，同步到 https-config.yaml
# =================================================================

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 证书配置
CERT_DIR="$HOME/.acme.sh/caringfamily.cn_ecc"
CERT_FILE="$CERT_DIR/fullchain.cer"
KEY_FILE="$CERT_DIR/caringfamily.cn.key"
HTTPS_CONFIG_FILE="k8s/https-config.yaml"
RENEW_DAYS=60

# 函数：检查证书是否存在且在有效期内
check_cert_valid() {
    local domain=$1
    local cert_path="$HOME/.acme.sh/${domain}_ecc/${domain}.cer"
    
    # 检查证书文件是否存在
    if [ ! -f "$cert_path" ]; then
        echo -e "${RED}[错误] 证书文件不存在: $cert_path${NC}"
        return 1
    fi
    
    # 获取证书过期时间
    local expiry_date=$(openssl x509 -in "$cert_path" -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -z "$expiry_date" ]; then
        echo -e "${RED}[错误] 无法读取证书过期时间${NC}"
        return 1
    fi
    
    # 计算剩余天数
    local expiry_ts=$(date -j -f "%b %d %H:%M:%S %Y %Z" "$expiry_date" +%s 2>/dev/null || date -d "$expiry_date" +%s 2>/dev/null)
    local current_ts=$(date +%s)
    local remaining_days=$(( (expiry_ts - current_ts) / 86400 ))
    
    echo "    证书剩余有效期: $remaining_days 天"
    
    if [ $remaining_days -le 0 ]; then
        echo -e "${RED}[错误] 证书已过期${NC}"
        return 1
    fi
    
    if [ $remaining_days -le $RENEW_DAYS ]; then
        echo -e "${YELLOW}[警告] 证书即将过期（少于 $RENEW_DAYS 天）${NC}"
    fi
    
    return 0
}

# 函数：base64 编码（不换行）
base64_encode() {
    if [ -f "$1" ]; then
        base64 -w 0 "$1" 2>/dev/null || base64 "$1" | tr -d '\n'
    else
        echo ""
    fi
}

# 函数：同步证书到 https-config.yaml
sync_cert_to_yaml() {
    echo ">>> 正在同步证书到 $HTTPS_CONFIG_FILE..."
    
    if [ ! -f "$HTTPS_CONFIG_FILE" ]; then
        echo -e "${RED}[错误] 配置文件不存在: $HTTPS_CONFIG_FILE${NC}"
        return 1
    fi
    
    # 检查证书和密钥文件
    if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
        echo -e "${RED}[错误] 证书或密钥文件不存在${NC}"
        return 1
    fi
    
    # base64 编码
    local cert_b64=$(base64_encode "$CERT_FILE")
    local key_b64=$(base64_encode "$KEY_FILE")
    
    if [ -z "$cert_b64" ] || [ -z "$key_b64" ]; then
        echo -e "${RED}[错误] 证书编码失败${NC}"
        return 1
    fi
    
    # 更新 https-config.yaml
    # 使用 sed 替换 tls.crt 和 tls.key 的内容
    local temp_file=$(mktemp)
    
    # 读取文件并替换
    awk -v cert="$cert_b64" -v key="$key_b64" '
        /^  tls\.crt:/ {
            print "  tls.crt: \"" cert "\""
            next
        }
        /^  tls\.key:/ {
            print "  tls.key: \"" key "\""
            next
        }
        { print }
    ' "$HTTPS_CONFIG_FILE" > "$temp_file"
    
    mv "$temp_file" "$HTTPS_CONFIG_FILE"
    
    echo -e "${GREEN}[成功] 证书已同步到 $HTTPS_CONFIG_FILE${NC}"
    return 0
}

# 主逻辑
echo "========================================"
echo "    证书检查和同步工具"
echo "========================================"
echo ""

# 检查证书
echo ">>> 检查证书状态..."
if ! check_cert_valid "caringfamily.cn"; then
    echo -e "${RED}[失败] 证书检查未通过${NC}"
    exit 1
fi

echo ""

# 同步到 YAML
if ! sync_cert_to_yaml; then
    echo -e "${RED}[失败] 证书同步失败${NC}"
    exit 1
fi

echo ""
echo "========================================"
echo -e "${GREEN}证书检查和同步完成！${NC}"
echo "========================================"
