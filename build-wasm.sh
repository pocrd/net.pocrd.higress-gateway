#!/bin/bash

# =================================================================
# Higress WASM 插件优雅编译脚本 (Go -> WASM)
# 适用环境: Go 1.24+, Higress 2.0+ 体系
# =================================================================

set -e

# --- Go 代理配置 ---
export GO111MODULE=on
export GOPROXY=https://goproxy.cn,direct

# --- 沙箱环境：使用项目内缓存目录 ---
export GOCACHE="${PWD}/.wasm-build-cache/go-build"
export GOMODCACHE="${PWD}/.wasm-build-cache/go-mod"
mkdir -p "${GOCACHE}" "${GOMODCACHE}"

# --- 配置区 ---
PLUGIN_DIR="higress-plugins"
OUTPUT_DIR="config/wasmplugins"

# --- 颜色输出 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage() {
    echo "用法: $0 [插件名称]"
    echo "示例: $0 auth-plugin"
}

init_dirs() {
    mkdir -p "${OUTPUT_DIR}"
}

# --- 检查是否需要编译 ---
# 比较源码和产物的修改时间，避免不必要的编译
need_rebuild() {
    local plugin_path=$1
    local output_file=$2
    
    # 根据操作系统选择 stat 参数
    local stat_cmd="stat -c %Y"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        stat_cmd="stat -f %m"
    fi
    
    # 找到最新的源码文件
    local latest_source=$(find "${plugin_path}" \( -name "*.go" -o -name "go.mod" -o -name "go.sum" \) -exec ${stat_cmd} {} \; 2>/dev/null | sort -n | tail -1)
    
    # 如果无法获取源码时间，默认需要编译
    if [ -z "${latest_source}" ]; then
        return 0
    fi
    
    # 检查产物是否需要重新编译
    if [ ! -f "${output_file}" ]; then
        return 0
    fi
    
    local wasm_time=$(${stat_cmd} "${output_file}" 2>/dev/null)
    if [ -z "${wasm_time}" ] || [ "${latest_source}" -gt "${wasm_time}" ]; then
        return 0
    fi
    
    return 1
}

# --- 核心编译逻辑 ---
build_plugin() {
    local plugin_name=$1
    local plugin_path="${PLUGIN_DIR}/${plugin_name}"
    local output_file="${OUTPUT_DIR}/${plugin_name}.wasm"

    if [ ! -d "${plugin_path}" ]; then
        echo -e "${RED}错误: 找不到插件目录 ${plugin_path}${NC}"
        return 1
    fi

    echo -e "${YELLOW}>>> 正在处理插件: ${plugin_name}${NC}"

    # 检查是否需要重新编译
    if ! need_rebuild "${plugin_path}" "${output_file}"; then
        echo -e "${GREEN}  插件已是最新，跳过编译${NC}"
        ls -lh "${output_file}" 2>/dev/null | awk '{print "  文件大小: " $5}'
        return 0
    fi

    # 1. 整理依赖
    echo "  [1/2] 正在整理依赖 (go mod tidy)..."
    (cd "${plugin_path}" && go mod tidy)

    # 2. 执行编译
    echo "  [2/2] 正在编译 WASM 产物..."
    (cd "${plugin_path}" && GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -o "../../${output_file}" .)

    if [ $? -ne 0 ]; then
        echo -e "${RED}编译失败: ${plugin_name}${NC}"
        return 1
    fi

    echo -e "${GREEN}成功生成: ${output_file}${NC}"
    ls -lh "${output_file}" | awk '{print "  文件大小: " $5}'
}

# --- 批量编译逻辑 ---
build_all_plugins() {
    for plugin_dir in ${PLUGIN_DIR}/*/; do
        if [ -d "${plugin_dir}" ] && [ -f "${plugin_dir}main.go" ]; then
            # 检查 main.go 是否为空或只有空白字符
            if [ ! -s "${plugin_dir}main.go" ] || ! grep -q '[^[:space:]]' "${plugin_dir}main.go"; then
                echo -e "${YELLOW}>>> 跳过插件: $(basename "${plugin_dir}") (main.go 为空)${NC}"
                continue
            fi
            build_plugin "$(basename "${plugin_dir}")"
            echo "----------------------------------------"
        fi
    done
}

# --- 输出 sha256 值 ---
# 用于 Helm values 配置
print_sha256() {
    echo -e "${YELLOW}>>> WASM 插件 sha256 值:${NC}"
    
    for wasm_file in ${OUTPUT_DIR}/*.wasm; do
        if [ -f "${wasm_file}" ]; then
            local plugin_name=$(basename "${wasm_file}" .wasm)
            local sha256=$(shasum -a 256 "${wasm_file}" | awk '{print $1}')
            
            echo "  ${plugin_name}:"
            echo "    sha256: ${sha256}"
        fi
    done
}

# --- OCI 镜像推送 ---
# 配置
REGISTRY="${REGISTRY:-localhost:5001}"
REPOSITORY_PREFIX="wasm-plugins"
OCI_TAG="${OCI_TAG:-v1.0.0}"

# 检查 oras 是否安装
check_oras() {
    if ! command -v oras &> /dev/null; then
        echo -e "${YELLOW}警告: 未安装 oras，跳过 OCI 镜像推送${NC}"
        echo "安装 oras: brew install oras"
        return 1
    fi
    return 0
}

# 推送单个插件到 OCI 仓库
push_oci_image() {
    local wasm_file=$1
    local plugin_name=$(basename "$wasm_file" .wasm)
    local image_url="${REGISTRY}/${REPOSITORY_PREFIX}/${plugin_name}:${OCI_TAG}"
    
    echo -e "${YELLOW}  推送 OCI 镜像: ${plugin_name}${NC}"
    echo "    镜像: ${image_url}"
    
    if oras push "${image_url}" \
        --artifact-type "application/vnd.wasm.config.v1+json" \
        "${wasm_file}:application/vnd.wasm.content.layer.v1+wasm" 2>/dev/null; then
        echo -e "    ${GREEN}成功: ${image_url}${NC}"
        echo "    在 k8s/wasmplugin-oci.yaml 中使用:"
        echo "      url: oci://${image_url}"
    else
        echo -e "    ${RED}失败: ${image_url}${NC}"
        return 1
    fi
}

# 推送所有插件
push_all_oci() {
    echo ""
    echo -e "${YELLOW}>>> 推送 OCI 镜像...${NC}"
    
    if ! check_oras; then
        return
    fi
    
    local found=false
    for wasm_file in ${OUTPUT_DIR}/*.wasm; do
        if [ -f "$wasm_file" ]; then
            found=true
            push_oci_image "$wasm_file"
            echo ""
        fi
    done
    
    if [ "$found" = false ]; then
        echo "  未找到 WASM 插件文件"
    fi
}

# --- 主入口 ---
main() {
    init_dirs

    echo "========================================"
    echo "    Higress WASM 构建工具"
    echo "========================================"

    # 解析参数
    local skip_oci=false
    local plugin_name=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-oci)
                skip_oci=true
                shift
                ;;
            --oci-only)
                push_all_oci
                exit 0
                ;;
            -h|--help)
                echo "用法: $0 [选项] [插件名称]"
                echo ""
                echo "选项:"
                echo "  --skip-oci    跳过 OCI 镜像推送"
                echo "  --oci-only    仅推送 OCI 镜像（不编译）"
                echo "  -h, --help    显示帮助"
                echo ""
                echo "环境变量:"
                echo "  REGISTRY      OCI 仓库地址 (默认: localhost:5000)"
                echo "  OCI_TAG       OCI 镜像标签 (默认: v1.0.0)"
                exit 0
                ;;
            *)
                plugin_name=$1
                shift
                ;;
        esac
    done

    # 编译插件
    if [ -z "$plugin_name" ]; then
        echo -e "${YELLOW}未指定插件，将尝试编译所有插件...${NC}\n"
        build_all_plugins
    else
        build_plugin "$plugin_name"
    fi

    # 输出 sha256
    echo ""
    print_sha256

    # 推送 OCI 镜像
    if [ "$skip_oci" = false ]; then
        push_all_oci
    fi

    echo ""
    echo -e "${GREEN}所有任务处理完毕。${NC}"
    echo ""
    echo "提示: 运行 ./deploy.sh 部署到 Kubernetes"
}

main "$@"