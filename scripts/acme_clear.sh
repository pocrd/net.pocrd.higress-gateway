#!/bin/bash

# 1. 定义需要清理的域名列表
DOMAINS=("caringfamily.cn" "www.caringfamily.cn" "res.caringfamily.cn" "*.caringfamily.cn")

echo ">>> 开始深度清理 acme.sh 订阅任务..."

for domain in "${DOMAINS[@]}"; do
    echo "-----------------------------------------------"
    echo "正在处理域名: $domain"
    
    # 2. 从 acme.sh 逻辑列表中移除（停止自动续期任务）
    ~/.acme.sh/acme.sh --remove -d "$domain"
    
    # 3. 物理删除对应的证书目录
    # 注意：acme.sh 默认会将证书存放在 域名_ecc 文件夹下
    CERT_DIR="$HOME/.acme.sh/${domain}_ecc"
    if [ -d "$CERT_DIR" ]; then
        echo "清理物理文件: $CERT_DIR"
        rm -rf "$CERT_DIR"
    else
        # 兼容非 ECC 证书目录
        CERT_DIR_RSA="$HOME/.acme.sh/${domain}"
        if [ -d "$CERT_DIR_RSA" ]; then
            echo "清理物理文件: $CERT_DIR_RSA"
            rm -rf "$CERT_DIR_RSA"
        fi
    fi
done

echo "-----------------------------------------------"
echo ">>> 清理完成！当前的订阅列表如下（应为空）："
~/.acme.sh/acme.sh --list