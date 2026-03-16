#!/bin/bash

# =================================================================
# Higress WASM 插件部署脚本 (K8s 模式) - 增强版
# =================================================================

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 参数初始化
BUILD_PLUGIN=false
SKIP_CERT=false
REINSTALL=false

# 解析参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -plugin)
            BUILD_PLUGIN=true
            shift
            ;;
        -skipCert)
            SKIP_CERT=true
            shift
            ;;
        -reinstall)
            REINSTALL=true
            shift
            ;;
        *)
            echo -e "${RED}未知参数: $1${NC}"
            echo "用法: ./deploy.sh [-plugin] [-skipCert] [-reinstall]"
            exit 1
            ;;
    esac
done

echo "========================================"
echo "    Higress WASM 插件部署工具 (K8s)"
echo "    模式: $([ "$REINSTALL" = true ] && echo -e "${RED}重新安装${NC}" || echo -e "${GREEN}增量更新${NC}")"
echo "========================================"

# --- 步骤 0: 证书检查 ---
if [ "$SKIP_CERT" = false ]; then
    echo -e "${YELLOW}[0/4] 检查并同步证书...${NC}"
    if [ -f "./scripts/load_new_cert.sh" ]; then
        ./scripts/load_new_cert.sh || { echo -e "${RED}证书检查失败${NC}"; exit 1; }
    fi
fi

# --- 步骤 1: 编译插件 ---
if [ "$BUILD_PLUGIN" = true ]; then
    echo -e "${YELLOW}[1/4] 编译 WASM 插件...${NC}"
    ./build-wasm.sh
fi

# --- 步骤 2: Helm 部署逻辑 ---
echo -e "${YELLOW}[2/4] 执行 Helm 部署...${NC}"

if ! command -v helm &> /dev/null || ! command -v kubectl &> /dev/null; then
    echo -e "${RED}错误：未找到 helm 或 kubectl 命令${NC}"
    exit 1
fi

# 确保命名空间存在
kubectl create namespace higress-system --dry-run=client -o yaml | kubectl apply -f -

if [ "$REINSTALL" = true ]; then
    echo -e "${RED}  检测到 -reinstall 标签，正在深度清理...${NC}"
    helm uninstall higress -n higress-system --wait 2>/dev/null || true
    
    # 核心：清理 Webhook，防止新安装的 Controller 无法工作
    kubectl delete validatingwebhookconfiguration higress-gateway-webhook-configuration 2>/dev/null || true
    
    # 核心：给端口释放预留时间
    echo "  等待端口释放..."
    sleep 5
    
    # 强制删除 Pod
    kubectl delete pods -n higress-system -l app.kubernetes.io/name=higress --force --grace-period=0 2>/dev/null || true
    echo "  深度清理完成"
fi

echo "  执行 Helm Repo 更新..."
helm repo add higress https://higress.io/helm-charts 2>/dev/null || true
helm repo update

echo "  应用 values.yaml 配置..."
# 使用 upgrade --install，如果是全新安装也会生效
helm upgrade --install higress higress/higress-core \
    -n higress-system \
    -f values.yaml \
    --wait --timeout 5m

# --- 步骤 3: 业务配置应用 ---
echo -e "${YELLOW}[3/4] 应用 k8s/ 目录业务配置...${NC}"

if [ -d "k8s" ]; then
    # 模式 A: 重新安装模式下，先彻底清理
    if [ "$REINSTALL" = true ]; then
        echo "  [强制模式] 正在清理旧业务配置资源..."
        kubectl delete -f k8s/ -n higress-system --ignore-not-found=true 2>/dev/null || true
        sleep 2
    fi

    # 模式 B: 无论是重装还是更新，都执行 Server-Side Apply
    echo "  正在通过 Server-Side Apply 同步配置..."
    # --server-side: 解决 resourceVersion 冲突的终极方案
    # --force-conflicts: 声明该 YAML 拥有字段的所有权，覆盖控制器的自动修改
    if ! kubectl apply -f k8s/ -n higress-system --server-side --force-conflicts; then
        echo -e "${RED}  Server-Side Apply 失败，尝试退回到普通 Apply...${NC}"
        kubectl apply -f k8s/ -n higress-system
    fi
else
    echo -e "${YELLOW}  跳过：未找到 k8s/ 目录${NC}"
fi

# --- 步骤 4: 状态检查 ---
echo -e "${YELLOW}[4/4] 检查部署状态...${NC}"
sleep 2
kubectl get pods -n higress-system
echo ""
kubectl get ingress,wasmplugin -n higress-system

echo "========================================"
echo -e "${GREEN}部署流程执行完毕！${NC}"
echo "========================================"