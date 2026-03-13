#!/bin/bash

# --- 1. 清理与初始化 ---
echo ">>> 正在清理旧的订阅记录以防冲突..."
~/.acme.sh/acme.sh --remove -d caringfamily.cn
~/.acme.sh/acme.sh --remove -d "*.caringfamily.cn"
~/.acme.sh/acme.sh --remove -d res.caringfamily.cn

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

# --- 2. 申请并部署：通配符证书 (供 Higress 使用) ---
echo ">>> 1/2 正在申请通配符证书 (*.caringfamily.cn)..."
~/.acme.sh/acme.sh --issue --dns dns_ali \
  -d caringfamily.cn \
  -d "*.caringfamily.cn"

echo ">>> 正在同步通配符证书到 Higress (K8s Secret)..."
~/.acme.sh/acme.sh --deploy -d caringfamily.cn \
  --deploy-hook kubernetes \
  --set-name caringfamily-wildcard-tls-secret \
  --set-namespace higress-system

# --- 3. 申请并部署：res 专用证书 (供 CDN 使用) ---
echo ">>> 2/2 正在申请 res.caringfamily.cn 专用证书..."
~/.acme.sh/acme.sh --issue --dns dns_ali \
  -d res.caringfamily.cn

echo ">>> 正在同步 res 证书到阿里云 CDN..."
# 此时 acme.sh 会自动匹配 CDN 实例中的 res.caringfamily.cn 并更新
~/.acme.sh/acme.sh --deploy -d res.caringfamily.cn --deploy-hook aliyun

echo ">>> [成功] 所有证书已进入自动化续期流程。"