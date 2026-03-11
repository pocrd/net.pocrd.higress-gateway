#!/bin/bash

# =================================================================
# Higress Helm 部署脚本
# 一键完成：编译插件 → 提取 sha256/base64 → 更新 values → Helm 部署
#
# 用法:
#   ./deploy.sh           # 首次部署或更新（默认）
#   ./deploy.sh --fresh   # 强制重新部署（删除后重建）
# =================================================================

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 配置
HELM_CHART="higress.io/higress-core"
VALUES_FILE="./values.yaml"
WASM_PLUGINS_DIR="config/wasmplugins"
K8S_MANIFESTS_DIR="./k8s"

# 解析参数
FRESH_DEPLOY=false
if [ "$1" == "--fresh" ]; then
    FRESH_DEPLOY=true
    echo -e "${YELLOW}注意: 使用强制重新部署模式${NC}"
fi

# 检查依赖
check_dependencies() {
    local missing=()
    
    if ! command -v helm &> /dev/null; then
        missing+=("helm")
    fi
    
    if ! command -v kubectl &> /dev/null; then
        missing+=("kubectl")
    fi
    
    if [ ${#missing[@]} -ne 0 ]; then
        echo -e "${RED}错误: 缺少以下依赖: ${missing[*]}${NC}"
        exit 1
    fi
}

# 步骤1：编译插件
build_plugins() {
    echo -e "${YELLOW}[1/4] 编译 WASM 插件...${NC}"
    
    if [ -f "./build-wasm.sh" ]; then
        ./build-wasm.sh
    else
        echo -e "${RED}错误: 找不到 build-wasm.sh 脚本${NC}"
        exit 1
    fi
    
    echo ""
}

# 步骤2：提取 sha256 并构建 OCI 镜像
extract_wasm_info() {
    echo -e "${YELLOW}[2/6] 提取 WASM 插件信息...${NC}"
    
    # 确保 wasm 插件目录存在
    if [ ! -d "${WASM_PLUGINS_DIR}" ]; then
        echo -e "${RED}错误: 找不到 WASM 插件目录 ${WASM_PLUGINS_DIR}${NC}"
        exit 1
    fi
    
    # 检查是否有 wasm 文件
    local found_plugin=false
    for wasm_file in "${WASM_PLUGINS_DIR}"/*.wasm; do
        if [ -f "${wasm_file}" ]; then
            found_plugin=true
            break
        fi
    done
    
    if [ "$found_plugin" = false ]; then
        echo "  未找到 wasm 插件文件"
        echo ""
        return
    fi
    
    # 检查是否需要构建 OCI 镜像
    if [ "${SKIP_OCI_PUSH:-false}" = "true" ]; then
        echo "  跳过 OCI 镜像推送 (SKIP_OCI_PUSH=true)"
    else
        echo "  推送 OCI 镜像..."
        if [ -f "./build-wasm.sh" ]; then
            ./build-wasm.sh --oci-only 2>/dev/null || echo -e "${YELLOW}  警告: OCI 镜像推送失败，继续部署...${NC}"
        fi
    fi
    
    echo ""
}

# 步骤3：验证 Helm Chart
verify_chart() {
    echo -e "${YELLOW}[3/6] 验证 Helm Chart...${NC}"
    
    # 验证 values 文件存在
    if [ ! -f "${VALUES_FILE}" ]; then
        echo -e "${RED}错误: 找不到 values 文件 ${VALUES_FILE}${NC}"
        exit 1
    fi
    
    echo -e "  ${GREEN}配置验证通过${NC}"
    echo ""
}

# 清理已存在的 release 和命名空间（仅在 --fresh 模式下使用）
cleanup_existing() {
    local release_name=$1
    local namespace=$2
    
    # 检查所有命名空间中是否存在同名 release
    local existing_ns=$(helm list --all-namespaces -q -f "^${release_name}$" | head -1)
    if [ -n "${existing_ns}" ]; then
        echo "  发现已存在的 Helm release '${release_name}'，正在清理..."
        helm uninstall "${release_name}" --wait 2>/dev/null || true
        echo "  已删除旧 release"
    fi
    
    # 检查命名空间是否正在终止
    if kubectl get namespace "${namespace}" 2>/dev/null | grep -q "Terminating"; then
        echo "  命名空间 ${namespace} 正在终止，等待清理完成..."
        while kubectl get namespace "${namespace}" 2>/dev/null | grep -q "Terminating"; do
            sleep 2
        done
        echo "  命名空间清理完成"
    fi
    
    # 如果命名空间存在但不在终止状态，询问是否删除
    if kubectl get namespace "${namespace}" 2>/dev/null >/dev/null; then
        echo "  命名空间 ${namespace} 已存在"
        # 检查是否有其他资源
        local resource_count=$(kubectl get all -n "${namespace}" --no-headers 2>/dev/null | wc -l)
        if [ "${resource_count}" -gt 0 ]; then
            echo "  检测到 ${resource_count} 个资源，执行强制清理..."
            kubectl delete all --all -n "${namespace}" --wait=false 2>/dev/null || true
            sleep 3
        fi
    fi
}

# 步骤4：部署到 Kubernetes
deploy_helm() {
    echo -e "${YELLOW}[4/6] 部署 Higress Core...${NC}"
    
    local release_name="higress"
    local namespace="higress-system"
    
    echo "  Release 名称: ${release_name}"
    echo "  命名空间: ${namespace}"
    echo "  Chart: ${HELM_CHART}"
    
    # 仅在 --fresh 模式下清理已存在的资源
    if [ "$FRESH_DEPLOY" = true ]; then
        echo -e "  ${YELLOW}强制重新部署模式：清理已存在的资源...${NC}"
        cleanup_existing "${release_name}" "${namespace}"
    fi
    
    # 使用官方 Chart 部署
    echo "  执行 helm upgrade --install..."
    if helm upgrade --install "${release_name}" "${HELM_CHART}" -f "${VALUES_FILE}" --create-namespace -n "${namespace}"; then
        echo ""
        echo -e "  ${GREEN}Higress Core 部署完成！${NC}"
    else
        echo ""
        echo -e "  ${RED}Higress Core 部署失败${NC}"
        exit 1
    fi
    
    echo ""
}

# 步骤5：部署 Nacos
deploy_nacos() {
    echo -e "${YELLOW}[5/6] 部署 Nacos...${NC}"
    
    local namespace="higress-system"
    
    if [ -f "${K8S_MANIFESTS_DIR}/nacos.yaml" ]; then
        echo "  部署 Nacos..."
        kubectl apply -f "${K8S_MANIFESTS_DIR}/nacos.yaml"
        
        # 等待 Nacos 就绪
        echo "  等待 Nacos 就绪..."
        kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=nacos -n "${namespace}" --timeout=120s || true
        echo ""
        echo -e "  ${GREEN}Nacos 部署完成！${NC}"
    else
        echo "  跳过 Nacos 部署（配置文件不存在）"
    fi
    
    echo ""
}

# 步骤6：部署额外的 K8s 资源
deploy_manifests() {
    echo -e "${YELLOW}[6/6] 部署额外 K8s 资源...${NC}"
    
    local namespace="higress-system"
    
    # 部署 McpBridge
    if [ -f "${K8S_MANIFESTS_DIR}/mcpbridge.yaml" ]; then
        echo "  部署 McpBridge..."
        kubectl apply -f "${K8S_MANIFESTS_DIR}/mcpbridge.yaml" --force
    fi
    
    # 部署 HTTPS 配置（如果证书已配置）
    if [ -f "${K8S_MANIFESTS_DIR}/https-config.yaml" ]; then
        echo "  部署 HTTPS 配置..."
        # 检查证书是否已填充
        if kubectl get secret https-server-secret -n "${namespace}" 2>/dev/null >/dev/null; then
            echo "    证书 Secret 已存在，跳过创建"
        else
            echo "    注意: https-server-secret 未创建，请手动配置证书"
            echo "    命令: kubectl create secret tls https-server-secret --cert=server.crt --key=server.key -n higress-system"
            echo "    或者编辑 k8s/https-config.yaml 填入 base64 编码的证书"
        fi
        # 应用 ConfigMap 配置
        kubectl apply -f "${K8S_MANIFESTS_DIR}/https-config.yaml" --force
    fi
    
    # 部署 Gateway
    if [ -f "${K8S_MANIFESTS_DIR}/gateway-simple.yaml" ]; then
        echo "  部署 Gateway..."
        kubectl apply -f "${K8S_MANIFESTS_DIR}/gateway-simple.yaml"
    fi
    
    # 部署 Ingress
    if [ -f "${K8S_MANIFESTS_DIR}/ingress.yaml" ]; then
        echo "  部署 Ingress..."
        kubectl apply -f "${K8S_MANIFESTS_DIR}/ingress.yaml"
    fi
    
    # 部署 HTTPRoute
    if [ -f "${K8S_MANIFESTS_DIR}/httproute.yaml" ]; then
        echo "  部署 HTTPRoute..."
        kubectl apply -f "${K8S_MANIFESTS_DIR}/httproute.yaml"
    fi
    
    # 部署 WasmPlugin（OCI 镜像方式）
    if [ -f "${K8S_MANIFESTS_DIR}/wasmplugin-oci.yaml" ]; then
        echo "  部署 WasmPlugin..."
        # 检查是否配置了正确的镜像地址
        if grep -q "localhost:5000" "${K8S_MANIFESTS_DIR}/wasmplugin-oci.yaml"; then
            echo "    注意: WasmPlugin 使用 localhost:5000 镜像地址"
            echo "    请确保已推送镜像或修改 k8s/wasmplugin-oci.yaml 中的 url 字段"
        fi
        kubectl apply -f "${K8S_MANIFESTS_DIR}/wasmplugin-oci.yaml"
    fi
    
    echo ""
    echo -e "  ${GREEN}额外资源部署完成！${NC}"
    echo ""
    echo "查看状态:"
    echo "  kubectl get pods -n ${namespace}"
    echo "  kubectl get svc -n ${namespace}"
    echo "  kubectl get httproute -n ${namespace}"
    echo "  kubectl get wasmplugin -n ${namespace}"
    echo ""
    echo "Nacos 控制台:"
    echo "  kubectl port-forward svc/nacos 8848:8848 -n ${namespace}"
    echo "  然后访问 http://localhost:8848/nacos"
    echo ""
    echo "查看日志:"
    echo "  kubectl logs -n ${namespace} deployment/higress-gateway"
}

# 主入口
main() {
    echo "========================================"
    echo "    Higress 官方 Chart 部署工具"
    echo "========================================"
    echo ""
    
    check_dependencies
    build_plugins
    extract_wasm_info
    verify_chart
    deploy_helm
    deploy_nacos
    deploy_manifests
    
    echo "========================================"
    echo -e "${GREEN}所有任务处理完毕！${NC}"
    echo "========================================"
}

main "$@"
