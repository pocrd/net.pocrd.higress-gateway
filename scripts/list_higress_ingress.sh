#!/bin/bash

# 查看 Higress Ingress 列表和详情
# 用法: ./list_higress_ingress.sh [ingress-name]

set -e

NAMESPACE="higress-system"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 打印带颜色的标题
print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================${NC}"
}

# 打印带颜色的信息
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查 kubectl 是否可用
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl 命令未找到，请确保已安装 kubectl 并配置好 kubeconfig"
        exit 1
    fi
}

# 获取 Ingress 列表
list_ingresses() {
    print_header "Higress Ingress 列表"
    
    # 获取所有 Ingress 的基本信息
    echo -e "\n${YELLOW}基本信息:${NC}"
    kubectl get ingress -n $NAMESPACE -o wide 2>/dev/null || {
        print_error "无法获取 Ingress 列表，请检查命名空间 $NAMESPACE 是否存在"
        exit 1
    }
    
    # 获取 Ingress 数量统计
    echo -e "\n${YELLOW}统计信息:${NC}"
    local count=$(kubectl get ingress -n $NAMESPACE --no-headers 2>/dev/null | wc -l)
    print_info "Higress Ingress 总数: $count"
}

# 获取指定 Ingress 详情
get_ingress_detail() {
    local ingress_name=$1
    
    print_header "Ingress 详情: $ingress_name"
    
    # 检查 Ingress 是否存在
    if ! kubectl get ingress "$ingress_name" -n $NAMESPACE &> /dev/null; then
        print_error "Ingress '$ingress_name' 不存在于命名空间 $NAMESPACE"
        exit 1
    fi
    
    # 基本信息
    echo -e "\n${YELLOW}1. 基本信息:${NC}"
    kubectl get ingress "$ingress_name" -n $NAMESPACE -o yaml | grep -E "(name:|namespace:|creationTimestamp:|uid:)" | head -10
    
    # 规则详情
    echo -e "\n${YELLOW}2. 路由规则:${NC}"
    kubectl get ingress "$ingress_name" -n $NAMESPACE -o jsonpath='{range .spec.rules[*]}{"  Host: "}{.host}{"\n"}{range .http.paths[*]}{"    Path: "}{.path}{"\n"}{"    PathType: "}{.pathType}{"\n"}{"    Service: "}{.backend.service.name}{":"}{.backend.service.port.number}{"\n\n"}{end}{end}'
    
    # TLS 配置
    echo -e "\n${YELLOW}3. TLS 配置:${NC}"
    local tls=$(kubectl get ingress "$ingress_name" -n $NAMESPACE -o jsonpath='{.spec.tls}' 2>/dev/null)
    if [ "$tls" != "[]" ] && [ -n "$tls" ]; then
        kubectl get ingress "$ingress_name" -n $NAMESPACE -o jsonpath='{range .spec.tls[*]}{"  SecretName: "}{.secretName}{"\n"}{"  Hosts: "}{.hosts}{"\n\n"}{end}'
    else
        echo "  无 TLS 配置"
    fi
    
    # 注解信息
    echo -e "\n${YELLOW}4. 注解 (Annotations):${NC}"
    kubectl get ingress "$ingress_name" -n $NAMESPACE -o jsonpath='{.metadata.annotations}' | jq -r 'to_entries[] | "  \(.key): \(.value)"' 2>/dev/null || {
        kubectl get ingress "$ingress_name" -n $NAMESPACE -o jsonpath='{range .metadata.annotations}{@}{"\n"}{end}'
    }
    
    # 完整 YAML
    echo -e "\n${YELLOW}5. 完整 YAML 配置:${NC}"
    kubectl get ingress "$ingress_name" -n $NAMESPACE -o yaml
}

# 获取所有 Ingress 的摘要信息
get_all_ingress_summary() {
    print_header "所有 Ingress 摘要"
    
    local ingresses=$(kubectl get ingress -n $NAMESPACE -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    
    if [ -z "$ingresses" ]; then
        print_warn "命名空间 $NAMESPACE 中没有找到任何 Ingress"
        return
    fi
    
    for ingress in $ingresses; do
        echo -e "\n${GREEN}--- $ingress ---${NC}"
        
        # 获取 Host 和 Path
        local rules=$(kubectl get ingress "$ingress" -n $NAMESPACE -o jsonpath='{range .spec.rules[*]}{.host}{" -> "}{range .http.paths[*]}{.path}{" ("}{.backend.service.name}{":"}{.backend.service.port.number}{") "}{end}{"\n"}{end}' 2>/dev/null)
        echo "  路由: $rules"
        
        # 获取 TLS 状态
        local tls=$(kubectl get ingress "$ingress" -n $NAMESPACE -o jsonpath='{.spec.tls}' 2>/dev/null)
        if [ "$tls" != "[]" ] && [ -n "$tls" ]; then
            echo "  TLS: 已启用"
        else
            echo "  TLS: 未启用"
        fi
        
        # 获取关键注解
        local annotations=$(kubectl get ingress "$ingress" -n $NAMESPACE -o jsonpath='{.metadata.annotations}' 2>/dev/null)
        if [ -n "$annotations" ] && [ "$annotations" != "null" ]; then
            local key_annotations=$(echo "$annotations" | jq -r 'keys[]' 2>/dev/null | grep -E "(higress|nginx)" | head -3 | tr '\n' ', ')
            if [ -n "$key_annotations" ]; then
                echo "  关键注解: ${key_annotations%, }"
            fi
        fi
    done
}

# 主函数
main() {
    check_kubectl
    
    if [ $# -eq 0 ]; then
        # 无参数时显示列表和摘要
        list_ingresses
        get_all_ingress_summary
    else
        # 有参数时显示指定 Ingress 详情
        get_ingress_detail "$1"
    fi
}

main "$@"
