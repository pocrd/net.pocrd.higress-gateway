#!/bin/bash

# =================================================================
# Higress WASM 插件部署脚本 (K8s 模式)
# 一键完成：编译插件 → 应用 K8s 配置
# 用法: ./deploy.sh [-plugin]
#   -plugin: 重新编译 WASM 插件
# =================================================================

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 解析参数
BUILD_PLUGIN=false
while [[ $# -gt 0 ]]; do
    case $1 in
        -plugin)
            BUILD_PLUGIN=true
            shift
            ;;
        *)
            echo -e "${RED}未知参数: $1${NC}"
            echo "用法: ./deploy.sh [-plugin]"
            echo "  -plugin: 重新编译 WASM 插件"
            exit 1
            ;;
    esac
done

echo "========================================"
echo "    Higress WASM 插件部署工具 (K8s)"
echo "========================================"
echo ""

# 步骤 1: 编译插件（仅当指定 -plugin 参数时）
if [ "$BUILD_PLUGIN" = true ]; then
    echo -e "${YELLOW}[1/3] 编译 WASM 插件...${NC}"
    if [ -f "./build-wasm.sh" ]; then
        ./build-wasm.sh
    else
        echo -e "${RED}错误：找不到 build-wasm.sh 脚本${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}[1/3] 跳过 WASM 插件编译 (使用 -plugin 参数启用)${NC}"
fi

echo ""

# 步骤 2: 检查并安装/更新 Higress
echo -e "${YELLOW}[2/3] 检查 Higress 安装状态...${NC}"

# 检查 kubectl 是否安装
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}错误：未找到 kubectl 命令${NC}"
    exit 1
fi

# 检查 higress-system 命名空间是否存在，不存在则创建
if ! kubectl get namespace higress-system &> /dev/null; then
    echo "  创建 higress-system 命名空间..."
    kubectl create namespace higress-system
fi

# 检测 Higress 是否已通过 Helm 安装
if ! command -v helm &> /dev/null; then
    echo -e "${RED}错误：未找到 helm 命令${NC}"
    exit 1
fi

if helm list -n higress-system | grep -q "higress"; then
    echo "  Higress 已安装，执行 Helm 更新..."
    helm repo update
    helm upgrade higress higress.io/higress-core -n higress-system -f values.yaml --wait --timeout 5m
    echo "  Higress 更新完成"
else
    echo "  Higress 未安装，执行 Helm 安装..."
    helm repo update
    helm install higress higress.io/higress-core -n higress-system -f values.yaml --wait --timeout 5m
    echo "  Higress 安装完成"
fi

# 步骤 3: 清理并应用业务配置
echo ""
echo -e "${YELLOW}[3/3] 清理并应用业务配置...${NC}"

# 先清理非 Helm 管理的配置（避免残留，但保留 Helm 默认资源）
echo "  清理非 Helm 管理的配置..."

# 清理自定义资源（ingress, mcpbridge, wasmplugin）
for resource in ingress mcpbridge wasmplugin; do
    # 先删除有 managed-by 标签但不是 Helm 的资源
    kubectl delete $resource -n higress-system --selector='app.kubernetes.io/managed-by!=Helm' 2>/dev/null || true
    # 再删除没有 managed-by 标签的资源
    kubectl delete $resource -n higress-system --selector='!app.kubernetes.io/managed-by' 2>/dev/null || true
done

# 清理 Secret（严格排除 Helm release secrets）
# 只删除明确有 managed-by 标签且不是 Helm 的 Secret
kubectl delete secret -n higress-system --selector='app.kubernetes.io/managed-by!=Helm' 2>/dev/null || true
# 不删除没有 managed-by 标签的 Secret（避免误删 Helm release secrets 和系统 secrets）

# 清理 ConfigMap
kubectl delete configmap -n higress-system --selector='app.kubernetes.io/managed-by!=Helm' 2>/dev/null || true
kubectl delete configmap -n higress-system --selector='!app.kubernetes.io/managed-by' 2>/dev/null || true

# 等待清理完成
sleep 2

# 应用 k8s/ 目录下所有 YAML 配置
echo "  应用 k8s/ 目录配置..."
if [ -d "k8s" ]; then
    # 只应用 .yaml 文件，按文件名排序确保顺序一致
    for yaml_file in k8s/*.yaml; do
        if [ -f "$yaml_file" ]; then
            echo "    应用: $(basename $yaml_file)"
            kubectl apply -f "$yaml_file" -n higress-system
        fi
    done
else
    echo -e "${YELLOW}  跳过：未找到 k8s/ 目录${NC}"
fi

echo ""
echo "  等待配置生效..."
sleep 3

# 检查配置状态
echo "  检查配置状态..."
kubectl get ingress,mcpbridge -n higress-system

echo ""
echo "========================================"
echo -e "${GREEN}部署完成！${NC}"
echo "========================================"
echo ""
echo "查看资源状态:"
echo "  kubectl get ingress,mcpbridge,wasmplugin -n higress-system"
echo ""
echo "查看日志:"
echo "  kubectl logs -n higress-system -l app.kubernetes.io/name=higress -f"
echo ""
