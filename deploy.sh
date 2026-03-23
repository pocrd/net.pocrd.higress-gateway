#!/bin/bash

# =================================================================
# Higress WASM 插件部署脚本 (K8s 模式) - 深度重装增强版
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
        -plugin) BUILD_PLUGIN=true; shift ;;
        -skipCert) SKIP_CERT=true; shift ;;
        -reinstall) REINSTALL=true; shift ;;
        *)
            echo -e "${RED}未知参数: $1${NC}"
            echo "用法: ./deploy.sh [-plugin] [-skipCert] [-reinstall]"
            exit 1
            ;;
    esac
done

echo "========================================"
echo "    Higress WASM 插件部署工具 (K8s)"
echo "    模式: $([ "$REINSTALL" = true ] && echo -e "${RED}语义级重新安装 (深度清理)${NC}" || echo -e "${GREEN}增量同步更新${NC}")"
echo "========================================\n"

# --- 步骤 0: 证书检查 ---
if [ "$SKIP_CERT" = false ]; then
    echo -e "${YELLOW}[0/4] 检查并同步证书...${NC}"
    if [ -f "./scripts/load_new_cert.sh" ]; then
        ./scripts/load_new_cert.sh || { echo -e "${RED}错误：证书检查失败${NC}"; exit 1; }
    fi
fi

# --- 步骤 1: 编译插件 ---
if [ "$BUILD_PLUGIN" = true ]; then
    echo -e "${YELLOW}[1/4] 编译 WASM 插件...${NC}"
    if [ -f "./build-wasm.sh" ]; then
        ./build-wasm.sh
    else
        echo -e "${RED}错误：找不到 build-wasm.sh${NC}"
        exit 1
    fi
fi

# --- 步骤 2: 核心部署与彻底清理逻辑 ---
echo -e "${YELLOW}[2/4] 执行部署准备...${NC}"

# 确保命名空间存在
kubectl create namespace higress-system --dry-run=client -o yaml | kubectl apply -f -

if [ "$REINSTALL" = true ]; then
    echo -e "${RED}  >>> 开始深度清理环境 <<<${NC}"

    # 1. 按照 k8s 目录精准爆破业务资源 (确保 Nacos/Secret 等 AGE 重置)
    if [ -d "k8s" ]; then
        echo "  [1/5] 清理业务配置资源 (k8s/)..."
        kubectl delete -f k8s/ -n higress-system --ignore-not-found=true --timeout=30s 2>/dev/null || true
    fi

    # 2. 卸载 Helm 组件
    echo "  [2/5] 卸载 Higress Helm Release..."
    helm uninstall higress -n higress-system --wait 2>/dev/null || true

    # 3. 清理集群级 Webhook (防止新安装被拦截)
    echo "  [3/5] 清理集群级 Webhook 钩子..."
    kubectl delete validatingwebhookconfiguration -l "app.kubernetes.io/name=higress" 2>/dev/null || true
    kubectl delete mutatingwebhookconfiguration -l "app.kubernetes.io/name=higress" 2>/dev/null || true

    # 4. 暴力清理命名空间内所有残留 (Secret/ConfigMap/PVC/CRD)
    echo "  [4/5] 抹除命名空间内所有残留资源..."
    kubectl delete all,pvc,configmap,secret,wasmplugin,mcpbridge -n higress-system --all --force --grace-period=0 2>/dev/null || true

    # 5. 动态检测端口释放 (解决 0/1 状态的关键)
    echo -ne "  [5/5] 正在检测 80/443 端口释放情况..."
    
    # 循环检查 80/443 是否还在被监听
    # 检测可用命令
    if command -v ss >/dev/null 2>&1; then
        PORT_CHECK_CMD="ss -tln"
    elif command -v netstat >/dev/null 2>&1; then
        PORT_CHECK_CMD="netstat -tln"
    else
        echo -e "${RED}错误：未找到 ss 或 netstat 命令，请安装 iproute2 或 net-tools${NC}"
        exit 1
    fi

    # 循环检测端口释放
    MAX_WAIT=20
    for ((i=1; i<=$MAX_WAIT; i++)); do
        if $PORT_CHECK_CMD | grep -qE ':(80|443)\s'; then
            echo -ne "."
            sleep 1
        else
            echo -e "${GREEN} 已释放!${NC}"
            break
        fi

        if [ $i -eq $MAX_WAIT ]; then
            echo -e "${RED} 警告：端口在 20s 后仍未释放，尝试强行安装...${NC}"
        fi
    done

    # 补偿性冷却：即使端口状态显示消失，内核完全清理连接仍需极短时间
    # 1-2 秒的冷却可以显著降低 Envoy 启动时的 Address In Use 冲突风险
    sleep 2
    echo -e "${GREEN} 环境已彻底净化！${NC}\n"
fi

# 执行 Helm 安装/更新
echo "  同步 Helm Repo..."
helm repo add higress https://higress.io/helm-charts 2>/dev/null || true
helm repo update

echo "  正在部署 Higress 核心组件..."
helm upgrade --install higress higress/higress-core \
    -n higress-system \
    -f values.yaml \
    --wait --timeout 5m

# --- 步骤 3: 业务配置应用 ---
echo -e "${YELLOW}[3/4] 同步业务配置...${NC}"

if [ -d "k8s" ]; then
    # 检查 wasmplugin-oci.yaml 中的镜像标签
    if [ -f "k8s/wasmplugin-oci.yaml" ]; then
        echo "  检查 WASM 插件镜像标签..."
        local yaml_tag=$(grep "caringfamily/auth-plugin:" k8s/wasmplugin-oci.yaml | head -1 | sed 's/.*caringfamily\/auth-plugin:\([^ ]*\).*/\1/')
        if [ -n "$yaml_tag" ]; then
            echo "    当前使用镜像标签：${yaml_tag}"
        fi
    fi
    
    echo "  正在通过 Server-Side Apply 应用配置..."
    # --server-side: 解决所有 resourceVersion 冲突，是 K8s 1.22+ 的推荐做法
    # --force-conflicts: 确保本地 YAML 始终覆盖集群状态
    kubectl apply -f k8s/ -n higress-system --server-side --force-conflicts
else
    echo -e "${YELLOW}  跳过：未找到 k8s/ 目录${NC}"
fi

# --- 步骤 4: 状态检查 ---
echo -e "${YELLOW}[4/4] 检查部署状态...${NC}"
sleep 5
kubectl get pods -n higress-system
echo ""
kubectl get ingress,wasmplugin,mcpbridge -n higress-system

echo "========================================"
echo -e "${GREEN}部署成功！环境已处于最新状态。${NC}"
echo "========================================"