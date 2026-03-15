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
    local cert_dir="$HOME/.acme.sh/${domain}_ecc"
    
    # 检查证书是否存在
    if [ ! -f "$cert_dir/$domain.cer" ]; then
        return 0  # 需要申请
    fi
    
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
    
    # 申请证书
    ~/.acme.sh/acme.sh --issue --dns dns_ali \
        -d caringfamily.cn \
        -d "*.caringfamily.cn"
else
    echo "    证书有效期充足，跳过申请"
fi

# 始终执行部署（确保 K8s 和 CLB 上有证书）
echo ">>> 正在同步通配符证书到 Higress (K8s Secret)..."
~/.acme.sh/acme.sh --deploy -d caringfamily.cn \
    --deploy-hook kubernetes \
    --set-name caringfamily-wildcard-tls-secret \
    --set-namespace higress-system

echo ">>> 正在上传证书到阿里云 CLB..."
export CLB_REGION
export CLB_CERT_NAME
~/.acme.sh/acme.sh --deploy -d caringfamily.cn --deploy-hook aliyun
echo "    证书已上传到 CLB: $CLB_CERT_NAME"

# --- 2. 检查并部署 res 专用证书 ---
echo ""
echo ">>> 检查 res.caringfamily.cn 证书状态..."
if check_cert_renewal "res.caringfamily.cn"; then
    echo "    证书即将过期或不存在，执行申请..."
    
    # 清理旧记录
    ~/.acme.sh/acme.sh --remove -d res.caringfamily.cn 2>/dev/null || true
    
    # 申请证书
    ~/.acme.sh/acme.sh --issue --dns dns_ali \
        -d res.caringfamily.cn
else
    echo "    证书有效期充足，跳过申请"
fi

# 始终执行部署到 CDN
echo ">>> 正在同步 res 证书到阿里云 CDN..."
~/.acme.sh/acme.sh --deploy -d res.caringfamily.cn --deploy-hook aliyun

echo ""
echo ">>> [成功] 证书检查完成。"