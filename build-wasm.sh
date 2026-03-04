#!/bin/bash

# =================================================================
# Higress WASM 插件优雅编译脚本 (Go -> WASM)
# 适用环境: Go 1.21.13, TinyGo 0.30.0, Dubbo 3.3 体系
# =================================================================

set -e

# --- 配置区 ---
# 使用官方阿里云镜像，确保在国内 Docker 环境下拉取速度
TINYGO_IMAGE="ghcr.io/tinygo-org/tinygo:0.30.0"
PLUGIN_DIR="higress-plugins"
OUTPUT_DIR="higress-data/wasmplugins"
CACHE_DIR=".wasm-build-cache"

# --- 颜色输出 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage() {
    echo "用法: $0 [插件名称]"
    echo "示例: $0 auth-plugin"
}

check_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装。${NC}"
        exit 1
    fi
}

init_dirs() {
    mkdir -p "${OUTPUT_DIR}"
    mkdir -p "${CACHE_DIR}/go-mod"
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

    # 1. 整理依赖 (go mod tidy)
    # 使用容器环境确保依赖被正确下载到缓存目录，避免污染宿主机 go 环境
    echo "  [1/2] 正在整理依赖 (go mod tidy)..."
    docker run --rm \
        -v "$(pwd):/workspace" \
        -v "$(pwd)/${CACHE_DIR}/go-mod:/go/pkg/mod" \
        -w "/workspace/${plugin_path}" \
        -e GOPROXY=https://goproxy.cn,direct \
        -e GOMODCACHE=/go/pkg/mod \
        ${TINYGO_IMAGE} \
        /bin/sh -c "go mod tidy"

    # 2. 执行编译
    # 目标平台设为 wasi (TinyGo 0.30.0 支持)
    # 使用 leaking GC 提升网关插件性能 (Higress 推荐)
    echo "  [2/2] 正在编译 WASM 产物..."
    docker run --rm \
        -v "$(pwd):/workspace" \
        -v "$(pwd)/${CACHE_DIR}/go-mod:/go/pkg/mod" \
        -w "/workspace/${plugin_path}" \
        -e GOMODCACHE=/go/pkg/mod \
        ${TINYGO_IMAGE} \
        tinygo build -o "/workspace/${output_file}" \
        -target=wasi \
        -gc=leaking \
        -no-debug \
        -opt=2 \
        .

    if [ $? -eq 0 ]; then
        # 修正文件权限，确保宿主机当前用户可读写（针对 Linux 环境）
        if [[ "$OSTYPE" != "darwin"* ]]; then
            sudo chown $(id -u):$(id -g) "${output_file}" > /dev/null 2>&1 || true
        fi
        
        echo -e "${GREEN}成功生成: ${output_file}${NC}"
        ls -lh "${output_file}" | awk '{print "  文件大小: " $5}'
    else
        echo -e "${RED}编译失败: ${plugin_name}${NC}"
        return 1
    fi
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

# --- 生成 WasmPlugin 配置 ---
# 为每个插件生成独立的 .yaml 配置文件到 conf 目录
generate_wasmplugin_config() {
    local config_dir="higress-data/conf"
    
    mkdir -p "${config_dir}"
    
    echo -e "${YELLOW}>>> 正在生成 WasmPlugin 配置...${NC}"
    
    for wasm_file in ${OUTPUT_DIR}/*.wasm; do
        if [ -f "${wasm_file}" ]; then
            local plugin_name=$(basename "${wasm_file}" .wasm)
            local config_file="${config_dir}/${plugin_name}.yaml"
            local sha256=$(shasum -a 256 "${wasm_file}" | awk '{print $1}')
            local file_size=$(stat -f%z "${wasm_file}" 2>/dev/null || stat -c%s "${wasm_file}" 2>/dev/null)
            
            cat > "${config_file}" << EOF
# Higress WASM 插件配置文件
# 由 build-wasm.sh 自动生成，请勿手动修改
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 插件名称: ${plugin_name}
#
apiVersion: extensions.higress.io/v1alpha1
kind: WasmPlugin
metadata:
  name: ${plugin_name}
  namespace: higress-system
  annotations:
    higress.io/wasm-plugin-title: ${plugin_name}
    higress.io/wasm-plugin-description: Auto-generated WASM plugin
    higress.io/wasm-plugin-built-in: "false"
    higress.io/wasm-plugin-category: custom
spec:
  defaultConfigDisable: false
  failStrategy: FAIL_OPEN
  phase: AUTHN
  priority: 300
  sha256: ${sha256}
  url: file:///data/wasmplugins/${plugin_name}.wasm
  matchRules:
  - config: {}
    configDisable: false
    ingress:
    - default
EOF
            echo "  已生成: ${config_file} (sha256: ${sha256:0:16}..., size: ${file_size} bytes)"
        fi
    done
    
    echo -e "${GREEN}所有配置文件已生成到: ${config_dir}/${NC}"
}

# --- 主入口 ---
main() {
    check_docker
    init_dirs

    echo "========================================"
    echo "    Higress WASM 构建工具 (No-Hack 版)"
    echo "========================================"

    if [ -z "$1" ]; then
        echo -e "${YELLOW}未指定插件，将尝试编译所有插件...${NC}\n"
        build_all_plugins
    else
        build_plugin "$1"
    fi

    # 编译完成后自动生成 WasmPlugin 配置
    echo ""
    generate_wasmplugin_config

    echo -e "\n${GREEN}所有任务处理完毕。${NC}"
    echo -e "${YELLOW}提示: 配置文件已生成在 higress-data/conf/wasmplugins.yaml，Higress Controller 会自动加载${NC}"
}

main "$@"