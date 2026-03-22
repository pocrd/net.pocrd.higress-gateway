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
# 阿里云 ACR 配置
ACR_REGISTRY_VPC="crpi-76icqljpukx0sgec-vpc.cn-hangzhou.personal.cr.aliyuncs.com"
ACR_REGISTRY_PUBLIC="crpi-76icqljpukx0sgec.cn-hangzhou.personal.cr.aliyuncs.com"
ACR_REPOSITORY="caringfamily"
OCI_TAG="${OCI_TAG:-v1.0.1}"

# 获取有效的 ACR 仓库地址（优先内网，失败则用公网）
get_acr_registry() {
    # 先尝试内网地址
    if curl -sf "https://${ACR_REGISTRY_VPC}/v2/" --max-time 5 &>/dev/null || \
       curl -sf "http://${ACR_REGISTRY_VPC}:80/v2/" --max-time 5 &>/dev/null; then
        echo "${ACR_REGISTRY_VPC}"
        return 0
    fi
    
    # 内网失败，使用公网地址
    echo "${ACR_REGISTRY_PUBLIC}"
    return 0
}

# 检查 oras 是否安装
check_oras() {
    if ! command -v oras &> /dev/null; then
        echo -e "${YELLOW}警告: 未安装 oras，跳过 OCI 镜像推送${NC}"
        echo "安装 oras: brew install oras"
        return 1
    fi
    return 0
}

# 检查是否已登录阿里云 ACR
# 支持 docker 或 oras 登录
check_acr_login() {
    local registry=$1
    
    echo -e "${YELLOW}  正在检查 ACR 登录状态...${NC}"
    
    # 方法 1: 检查 oras 是否已登录（最可靠）
    if oras resolve "${registry}/${ACR_REPOSITORY}/auth-plugin:v1.0.0" &>/dev/null 2>&1; then
        echo -e "${GREEN}  ✓ 检测到有效的 oras 登录凭证${NC}"
        return 0
    fi
    echo -e "${YELLOW}  ✗ oras 未登录或凭证无效${NC}"
    
    # 方法 2: 检查 Docker config.json 中是否有有效的 auth 字段
    if [ -f "$HOME/.docker/config.json" ]; then
        echo -e "${YELLOW}  检查 Docker config.json...${NC}"
        
        # 检查是否有该仓库的 auth 认证信息（不是空对象）
        if grep -q "\"${registry}\"" "$HOME/.docker/config.json" 2>/dev/null; then
            echo -e "${YELLOW}  找到仓库配置：${registry}${NC}"
            
            # 进一步检查是否有 auth 字段
            if grep -A 1 "\"${registry}\"" "$HOME/.docker/config.json" | grep -q '"auth"'; then
                echo -e "${GREEN}  ✓ 检测到 Docker 认证凭据，尝试使用${NC}"
                
                # 尝试推送测试镜像验证凭据是否有效（使用与 push_oci_image 相同的参数）
                local test_tag="test-login-$(date +%s)"
                local tmp_dir=$(mktemp -d)
                
                # 创建测试文件
                echo "{}" > "${tmp_dir}/config.json"
                echo "test" > "${tmp_dir}/test.wasm"
                (cd "$tmp_dir" && tar -czf layer.tar.gz test.wasm)
                
                echo -e "${YELLOW}  尝试推送测试镜像验证凭据...${NC}"
                if oras push "${registry}/${ACR_REPOSITORY}/${test_tag}:test" \
                    --disable-path-validation \
                    --config "${tmp_dir}/config.json:application/vnd.oci.image.config.v1+json" \
                    "${tmp_dir}/layer.tar.gz:application/vnd.oci.image.layer.v1.tar+gzip" &>/dev/null 2>&1; then
                    # 清理测试镜像
                    oras delete "${registry}/${ACR_REPOSITORY}/${test_tag}:test" &>/dev/null 2>&1 || true
                    rm -rf "$tmp_dir"
                    echo -e "${GREEN}  ✓ Docker 凭证有效，oras 可以复用${NC}"
                    return 0
                fi
                
                rm -rf "$tmp_dir"
                echo -e "${RED}  ✗ Docker 凭据已过期或无效，请重新登录${NC}"
            else
                echo -e "${YELLOW}  ✗ Docker 配置中缺少 auth 字段，请重新登录${NC}"
            fi
        else
            echo -e "${YELLOW}  ✗ Docker 配置中未找到仓库：${registry}${NC}"
        fi
    else
        echo -e "${YELLOW}  ✗ Docker config.json 不存在${NC}"
    fi
    
    # 打印详细的登录提示信息
    echo ""
    echo -e "${RED}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}  错误：未登录阿里云容器镜像仓库 (ACR)${NC}"
    echo -e "${RED}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}【原因】${NC}"
    echo "  Docker 或 oras 未登录到阿里云 ACR，无法推送 OCI 镜像"
    echo ""
    echo -e "${YELLOW}【解决方案】${NC}"
    echo "  请在执行本脚本前，先手动登录到阿里云容器镜像仓库："
    echo ""
    echo -e "  ${GREEN}docker login --username=<你的阿里云账号> --password=<你的访问密码> ${registry}${NC}"
    echo ""
    echo "  或使用 oras 登录："
    echo -e "  ${GREEN}oras login ${registry} --username=<你的阿里云账号>${NC}"
    echo ""
    echo -e "${YELLOW}【如何获取登录信息】${NC}"
    echo "  1. 登录阿里云控制台 (https://cr.console.aliyun.com)"
    echo "  2. 进入「实例」-> 选择对应实例 ->「仓库凭证」"
    echo "  3. 使用显示的固定密码或创建新的访问密码"
    echo ""
    echo -e "${YELLOW}【提示】${NC}"
    echo "  - 登录信息会保存在 ~/.docker/config.json 中"
    echo "  - 后续执行无需重复登录，除非凭证过期或被清除"
    echo ""
    echo -e "${RED}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}跳过 OCI 镜像推送${NC}"
    return 1
}

# 推送单个插件到 OCI 仓库
# 使用标准 OCI Image 格式（2层：config + layer），兼容 Higress 2.2.0
push_oci_image() {
    local wasm_file=$1
    local plugin_name=$(basename "$wasm_file" .wasm)
    local registry=$(get_acr_registry)
    local image_url="${registry}/${ACR_REPOSITORY}/${plugin_name}:${OCI_TAG}"
    local tmp_dir=$(mktemp -d)
    
    echo -e "${YELLOW}  推送 OCI 镜像: ${plugin_name}${NC}"
    echo "    仓库: ${registry}"
    echo "    镜像: ${image_url}"
    
    # 创建符合 Higress 2.2.0 要求的 OCI Image 格式
    # 需要：1) config.json（空配置） 2) layer.tar.gz（wasm 文件压缩）
    
    # 1. 创建空的 config.json
    echo "{}" > "${tmp_dir}/config.json"
    
    # 2. 将 wasm 文件打包为 tar.gz
    # Higress 期望 tar 包内的文件名为 plugin.wasm
    cp "$wasm_file" "${tmp_dir}/plugin.wasm"
    (cd "$tmp_dir" && tar -czf layer.tar.gz "plugin.wasm")
    
    # 3. 使用标准 OCI Image 格式推送
    # 使用 --disable-path-validation 允许使用临时目录的绝对路径
    if oras push "${image_url}" \
        --disable-path-validation \
        --config "${tmp_dir}/config.json:application/vnd.oci.image.config.v1+json" \
        "${tmp_dir}/layer.tar.gz:application/vnd.oci.image.layer.v1.tar+gzip"; then
        echo -e "    ${GREEN}成功: ${image_url}${NC}"
        echo "    在 k8s/wasmplugin-oci.yaml 中使用:"
        echo "      url: oci://${image_url}"
    else
        echo -e "    ${RED}失败: ${image_url}${NC}"
        rm -rf "$tmp_dir"
        return 1
    fi
    
    rm -rf "$tmp_dir"
}

# 推送所有插件
push_all_oci() {
    echo ""
    echo -e "${YELLOW}>>> 推送 OCI 镜像...${NC}"
    
    if ! check_oras; then
        return
    fi
    
    # 获取仓库地址并检查登录状态
    local registry=$(get_acr_registry)
    if ! check_acr_login "$registry"; then
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
                echo "  OCI_TAG       OCI 镜像标签 (默认: v1.0.1)"
                echo ""
                echo "阿里云 ACR 配置:"
                echo "  内网仓库: ${ACR_REGISTRY_VPC}"
                echo "  公网仓库: ${ACR_REGISTRY_PUBLIC}"
                echo "  命名空间: ${ACR_REPOSITORY}"
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