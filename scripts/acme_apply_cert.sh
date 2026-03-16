#!/bin/bash

# 阿里云 CLB 配置
CLB_REGION="cn-hangzhou"
CLB_CERT_NAME="caringfamily-wildcard"

# 证书有效期阈值（天）
RENEW_DAYS=60

# 函数：检查证书是否需要更新
# 参数：域名
# 返回：0 需要更新，1 不需要更新
check_cert_renewal() {
    local domain=$1
    # 优先检查 RSA 格式，然后检查 ECC 格式
    local cert_dir="$HOME/.acme.sh/${domain}"
    if [ ! -f "$cert_dir/$domain.cer" ]; then
        cert_dir="$HOME/.acme.sh/${domain}_ecc"
    fi
    
    # 调试输出
    echo "    [调试] 检查证书路径: $cert_dir/$domain.cer"
    
    # 检查证书是否存在
    if [ ! -f "$cert_dir/$domain.cer" ]; then
        echo "    [调试] 证书文件不存在"
        return 0  # 需要申请
    fi
    echo "    [调试] 证书文件存在"
    
    # 获取证书过期时间
    local expiry_date=$(openssl x509 -in "$cert_dir/$domain.cer" -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -z "$expiry_date" ]; then
        return 0  # 无法读取，需要申请
    fi
    
    # 计算剩余天数
    local expiry_ts=$(date -j -f "%b %d %H:%M:%S %Y %Z" "$expiry_date" +%s 2>/dev/null || date -d "$expiry_date" +%s 2>/dev/null)
    local current_ts=$(date +%s)
    local remaining_days=$(( (expiry_ts - current_ts) / 86400 ))
    
    echo "    证书剩余有效期: $remaining_days 天"
    
    if [ $remaining_days -gt $RENEW_DAYS ]; then
        return 1  # 不需要更新
    else
        return 0  # 需要更新
    fi
}

# --- 1. 检查并部署通配符证书 ---
echo ">>> 检查通配符证书 (*.caringfamily.cn) 状态..."
NEED_ISSUE=false
if check_cert_renewal "caringfamily.cn"; then
    echo "    证书即将过期或不存在，执行申请..."
    NEED_ISSUE=true
    
    # 清理旧记录
    ~/.acme.sh/acme.sh --remove -d caringfamily.cn 2>/dev/null || true
    ~/.acme.sh/acme.sh --remove -d "*.caringfamily.cn" 2>/dev/null || true
    
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        
    # 申请证书 (使用 ECC P-256 椭圆曲线)
    ~/.acme.sh/acme.sh --issue --dns dns_ali \
        --keylength ec-256 \
        -d caringfamily.cn \
        -d "*.caringfamily.cn"
else
    echo "    证书有效期充足，跳过申请"
fi

# 始终执行部署（确保 K8s 和 CLB 上有证书）
echo ">>> 正在同步通配符证书到 Higress (K8s Secret)..."
# 优先使用 RSA 格式证书（CLB 不支持 ECC）
if [ -d "$HOME/.acme.sh/caringfamily.cn" ]; then
    CERT_DIR="$HOME/.acme.sh/caringfamily.cn"
else
    CERT_DIR="$HOME/.acme.sh/caringfamily.cn_ecc"
fi
CERT_FILE="$CERT_DIR/fullchain.cer"
KEY_FILE="$CERT_DIR/caringfamily.cn.key"

if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
    # 使用 kubectl 直接创建/更新 Secret
    kubectl create secret tls https-server-secret \
        --cert="$CERT_FILE" \
        --key="$KEY_FILE" \
        -n higress-system \
        --dry-run=client -o yaml | kubectl apply -f -
    echo "    证书已同步到 K8s Secret: https-server-secret"
else
    echo "    [错误] 证书文件不存在，跳过 K8s 同步"
fi

echo ">>> 正在上传证书到阿里云 CLB..."
# 优先使用 RSA 格式证书（CLB 不支持 ECC）
if [ -d "$HOME/.acme.sh/caringfamily.cn" ]; then
    CERT_DIR="$HOME/.acme.sh/caringfamily.cn"
else
    CERT_DIR="$HOME/.acme.sh/caringfamily.cn_ecc"
fi
# CLB 需要单独的证书和中间链，不是 fullchain
CERT_FILE="$CERT_DIR/caringfamily.cn.cer"
CA_FILE="$CERT_DIR/ca.cer"
KEY_FILE="$CERT_DIR/caringfamily.cn.key"

# 合并证书和 CA 链（CLB 格式要求）
# 使用 cat 直接合并，去除空行
if [ -f "$CA_FILE" ]; then
    CERT_CONTENT=$(cat "$CERT_FILE" "$CA_FILE" | grep -v '^$')
else
    CERT_CONTENT=$(cat "$CERT_FILE")
fi

if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
    if command -v aliyun &> /dev/null; then
        # 从 acme.sh 配置读取阿里云密钥
        ACME_ACCOUNT_CONF="$HOME/.acme.sh/account.conf"
        ALI_KEY=$(grep "^SAVED_Ali_Key=" "$ACME_ACCOUNT_CONF" 2>/dev/null | sed 's/^SAVED_Ali_Key=//; s/^["'\''"]//; s/["'\''"]$//')
        ALI_SECRET=$(grep "^SAVED_Ali_Secret=" "$ACME_ACCOUNT_CONF" 2>/dev/null | sed 's/^SAVED_Ali_Secret=//; s/^["'\''"]//; s/["'\''"]$//')
        
        if [ -z "$ALI_KEY" ] || [ -z "$ALI_SECRET" ]; then
            echo "    [错误] 未找到阿里云 AccessKey"
            exit 1
        fi
        
        # 调试：显示密钥长度和前几位（删除这行在生产环境）
        echo "    [调试] AccessKeyId: ${ALI_KEY:0:8}... (长度: ${#ALI_KEY})"
        echo "    [调试] 证书内容前50字符: ${CERT_CONTENT:0:50}..."
        
        # 配置 aliyun CLI（使用 acme.sh 的密钥）
        aliyun configure set \
            --access-key-id "$ALI_KEY" \
            --access-key-secret "$ALI_SECRET" \
            --region "$CLB_REGION" \
            --mode AK
        
        # 检查是否已存在同名证书
        EXISTING_CERT=$(aliyun slb DescribeServerCertificates \
            --RegionId "$CLB_REGION" \
            --ServerCertificateName "$CLB_CERT_NAME" 2>/dev/null | grep -o '"ServerCertificateId":"[^"]*"' | head -1 | cut -d'"' -f4)
        
        if [ -n "$EXISTING_CERT" ]; then
            echo "    发现已有证书，创建新版本..."
            NEW_CERT_NAME="${CLB_CERT_NAME}-$(date +%Y%m%d)"
        else
            NEW_CERT_NAME="$CLB_CERT_NAME"
        fi
        
        # 上传证书
        if aliyun slb UploadServerCertificate \
            --RegionId "$CLB_REGION" \
            --ServerCertificate "$CERT_CONTENT" \
            --PrivateKey "$(cat "$KEY_FILE")" \
            --ServerCertificateName "$NEW_CERT_NAME" \
            --ResourceGroupId "rg-acfm2rjmfrfahdi"; then
            echo "    证书已上传到 CLB: $NEW_CERT_NAME"
            echo "    注意: 请在阿里云控制台更新 CLB 监听器绑定的证书"
        else
            echo "    [错误] CLB 证书上传失败"
        fi
    else
        echo "    [警告] 未找到阿里云 CLI，跳过 CLB 证书上传"
    fi
else
    echo "    [错误] 证书文件不存在"
fi

# --- 2. 检查并部署 res 专用证书 ---
echo ""
echo ">>> 检查 res.caringfamily.cn 证书状态..."
if check_cert_renewal "res.caringfamily.cn"; then
    echo "    证书即将过期或不存在，执行申请..."
    
    # 清理旧记录
    ~/.acme.sh/acme.sh --remove -d res.caringfamily.cn 2>/dev/null || true
    
    # 申请证书 (使用 ECC P-256 椭圆曲线)
    ~/.acme.sh/acme.sh --issue --dns dns_ali \
        --keylength ec-256 \
        -d res.caringfamily.cn
else
    echo "    证书有效期充足，跳过申请"
fi

# 始终执行部署到 CDN（如果 ali_cdn 钩子存在）
echo ">>> 正在同步 res 证书到阿里云 CDN..."
if [ -f "$HOME/.acme.sh/deploy/ali_cdn.sh" ]; then
    # 从 acme.sh 配置文件读取阿里云 AccessKey
    ACME_ACCOUNT_CONF="$HOME/.acme.sh/account.conf"
    if [ -f "$ACME_ACCOUNT_CONF" ]; then
        # 读取 SAVED_Ali_Key 和 SAVED_Ali_Secret（支持带引号或不带引号的格式）
        export Ali_Key=$(grep "^SAVED_Ali_Key=" "$ACME_ACCOUNT_CONF" | sed 's/^SAVED_Ali_Key=//; s/^["'\''"]//; s/["'\''"]$//')
        export Ali_Secret=$(grep "^SAVED_Ali_Secret=" "$ACME_ACCOUNT_CONF" | sed 's/^SAVED_Ali_Secret=//; s/^["'\''"]//; s/["'\''"]$//')
    fi
    
    if [ -z "$Ali_Key" ] || [ -z "$Ali_Secret" ]; then
        echo "    [警告] 未找到阿里云 AccessKey，跳过 CDN 证书部署"
        echo "    请确保 account.conf 中包含 Ali_Key 和 Ali_Secret"
    else
        ~/.acme.sh/acme.sh --deploy -d res.caringfamily.cn --deploy-hook ali_cdn
    fi
else
    echo "    [警告] 未找到 ali_cdn 部署钩子，跳过 CDN 证书部署"
    echo "    如需 CDN 自动部署，请安装: curl -o ~/.acme.sh/deploy/ali_cdn.sh https://raw.githubusercontent.com/acmesh-official/acme.sh/master/deploy/ali_cdn.sh"
fi

echo ""
echo ">>> [成功] 证书检查完成。"
