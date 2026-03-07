#!/bin/bash

# =================================================================
# Higress WASM 插件优雅编译脚本 (Go -> WASM)
# 适用环境: Go 1.24+, Higress 2.0+ 体系
# =================================================================

set -e

# --- Go 代理配置 ---
export GO111MODULE=on
export GOPROXY=https://goproxy.cn,direct

# --- 配置区 ---
PLUGIN_DIR="higress-plugins"
OUTPUT_DIR="higress-data/wasmplugins"
CONFIG_OUTPUT_DIR="config/wasmplugins"

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
    mkdir -p "${CONFIG_OUTPUT_DIR}"
}

# --- 检查是否需要编译 ---
# 比较源码和产物的修改时间，避免不必要的编译
need_rebuild() {
    local plugin_path=$1
    local output_file=$2
    local config_output_file=$3
    
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
    
    # 检查 higress-data/wasmplugins/ 下的产物
    local need_build=false
    if [ ! -f "${output_file}" ]; then
        need_build=true
    else
        local wasm_time=$(${stat_cmd} "${output_file}" 2>/dev/null)
        if [ -z "${wasm_time}" ] || [ "${latest_source}" -gt "${wasm_time}" ]; then
            need_build=true
        fi
    fi
    
    # 检查 config/wasmplugins/ 下的产物
    if [ ! -f "${config_output_file}" ]; then
        need_build=true
    else
        local config_wasm_time=$(${stat_cmd} "${config_output_file}" 2>/dev/null)
        if [ -z "${config_wasm_time}" ] || [ "${latest_source}" -gt "${config_wasm_time}" ]; then
            need_build=true
        fi
    fi
    
    if [ "$need_build" = true ]; then
        return 0
    fi
    
    return 1
}

# --- 核心编译逻辑 ---
build_plugin() {
    local plugin_name=$1
    local plugin_path="${PLUGIN_DIR}/${plugin_name}"
    local output_file="${OUTPUT_DIR}/${plugin_name}.wasm"
    local config_output_file="${CONFIG_OUTPUT_DIR}/${plugin_name}.wasm"

    if [ ! -d "${plugin_path}" ]; then
        echo -e "${RED}错误: 找不到插件目录 ${plugin_path}${NC}"
        return 1
    fi

    echo -e "${YELLOW}>>> 正在处理插件: ${plugin_name}${NC}"

    # 检查是否需要重新编译
    if ! need_rebuild "${plugin_path}" "${output_file}" "${config_output_file}"; then
        echo -e "${GREEN}  插件已是最新，跳过编译${NC}"
        ls -lh "${output_file}" 2>/dev/null | awk '{print "  higress-data文件大小: " $5}'
        ls -lh "${config_output_file}" 2>/dev/null | awk '{print "  config文件大小: " $5}'
        return 0
    fi

    # 1. 整理依赖
    echo "  [1/3] 正在整理依赖 (go mod tidy)..."
    (cd "${plugin_path}" && go mod tidy)

    # 2. 执行编译到 higress-data/wasmplugins/
    echo "  [2/3] 正在编译 WASM 产物..."
    (cd "${plugin_path}" && GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -o "../../${output_file}" .)

    if [ $? -ne 0 ]; then
        echo -e "${RED}编译失败: ${plugin_name}${NC}"
        return 1
    fi

    # 3. 复制到 config/wasmplugins/
    echo "  [3/3] 正在复制到 config/wasmplugins/..."
    cp "${output_file}" "${config_output_file}"

    echo -e "${GREEN}成功生成: ${output_file}${NC}"
    ls -lh "${output_file}" | awk '{print "  文件大小: " $5}'
    echo -e "${GREEN}成功复制: ${config_output_file}${NC}"
    ls -lh "${config_output_file}" | awk '{print "  文件大小: " $5}'
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
# 在 config/wasmplugins/ 目录下生成配置文件
generate_wasmplugin_config() {
    local config_dir="config/wasmplugins"
    
    mkdir -p "${config_dir}"
    
    echo -e "${YELLOW}>>> 正在生成 WasmPlugin 配置...${NC}"
    
    # 使用 config/wasmplugins/ 下的 wasm 文件计算 sha256
    for wasm_file in ${CONFIG_OUTPUT_DIR}/*.wasm; do
        if [ -f "${wasm_file}" ]; then
            local plugin_name=$(basename "${wasm_file}" .wasm)
            local config_file="${config_dir}/${plugin_name}.yaml"
            local sha256=$(shasum -a 256 "${wasm_file}" | awk '{print $1}')
            
            cat > "${config_file}" << EOF
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
  matchRules: []
EOF
            echo "  已生成: ${config_file}"
        fi
    done
    
    echo -e "${GREEN}所有配置文件已生成到: ${config_dir}/${NC}"
}

# --- 主入口 ---
main() {
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
}

main "$@"