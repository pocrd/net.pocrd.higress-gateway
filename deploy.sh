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

# 清理手动创建的资源（保留 Helm 模板生成的系统配置）
cleanup_manual_resources() {
    local namespace=$1
    
    echo "  清理手动创建的资源..."
    
    # 删除手动创建的 Ingress（Helm 创建的 Ingress 通常有 managed-by 标签）
    kubectl delete ingress -n "${namespace}" -l "app.kubernetes.io/managed-by!=Helm" --ignore-not-found=true 2>/dev/null || true
    
    # 删除 HTTPRoute 资源（Gateway API）- 通常是手动创建的
    kubectl delete httproute --all -n "${namespace}" --ignore-not-found=true 2>/dev/null || true
    
    # 删除手动创建的 WasmPlugin（Helm 创建的通常有 managed-by 标签）
    kubectl delete wasmplugin -n "${namespace}" -l "app.kubernetes.io/managed-by!=Helm" --ignore-not-found=true 2>/dev/null || true
    
    # 删除手动创建的 McpBridge（Helm 创建的通常有 managed-by 标签）
    kubectl delete mcpbridge -n "${namespace}" -l "app.kubernetes.io/managed-by!=Helm" --ignore-not-found=true 2>/dev/null || true
    
    # 删除手动创建的 ConfigMap（保留 Helm 和系统生成的）
    kubectl delete configmap higress-https -n "${namespace}" --ignore-not-found=true 2>/dev/null || true
    
    # 删除手动创建的 Secret（保留 Helm 和系统生成的 CA 证书）
    kubectl delete secret https-server-secret https-server-secret-cacert -n "${namespace}" --ignore-not-found=true 2>/dev/null || true
    
    # 删除其他非 Helm 管理的资源
    kubectl delete pods,services,deployments,statefulsets -n "${namespace}" -l "app.kubernetes.io/managed-by!=Helm" --wait=false 2>/dev/null || true
}

# 步骤4：部署到 Kubernetes
deploy_helm() {
    echo -e "${YELLOW}[4/6] 部署 Higress Core...${NC}"
    
    local release_name="higress"
    local namespace="higress-system"
    
    echo "  Release 名称: ${release_name}"
    echo "  命名空间: ${namespace}"
    echo "  Chart: ${HELM_CHART}"
    
    # 清理手动创建的资源（保留 Helm 管理的系统配置）
    cleanup_manual_resources "${namespace}"
    
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
