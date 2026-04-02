#!/bin/bash
# =============================================================================
# 从 Nacos 获取 Dubbo 服务并生成 Higress Ingress 配置
# 调用 generate_ingress_from_nacos.py 执行实际逻辑
# =============================================================================

set -e

# 默认配置
DEFAULT_NACOS_URL="http://localhost:30848"
DEFAULT_DOMAIN="api.caringfamily.cn"
DEFAULT_GROUP="PUBLIC-GROUP"

# -----------------------------------------------------------------------------
# 检查 kubectl 是否可用
# -----------------------------------------------------------------------------
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        echo "⚠️  kubectl 命令未找到"
        echo ""
        echo "请确保 kubectl 已安装并配置正确"
        echo ""
        exit 1
    fi

    # 检查是否能连接到 Kubernetes 集群
    if ! kubectl cluster-info &> /dev/null; then
        echo "⚠️  无法连接到 Kubernetes 集群"
        echo ""
        echo "请确保 kubectl 已正确配置并能访问集群"
        echo ""
        exit 1
    fi
}

# 显示帮助信息
show_help() {
    cat << EOF
用法: $0 [选项]

选项:
    -h, --help              显示帮助信息
    -n, --nacos URL         Nacos 服务器地址 (默认: ${DEFAULT_NACOS_URL})
    -d, --domain DOMAIN     Ingress 域名 (默认: ${DEFAULT_DOMAIN})
    -g, --group GROUP       Nacos 服务分组 (默认: ${DEFAULT_GROUP})
    --namespace ID          Nacos 命名空间 ID (默认: 空)
    -o, --output FILE       输出文件路径 (默认: 输出到 stdout)
    --dry-run               只生成配置，不同步到 Higress
    --mcp-only              只生成 McpBridge 配置
    --ingress-only          只生成 Ingress 配置

示例:
    $0 -n http://localhost:8848
    $0 -n http://localhost:8848 -d api.example.com
    $0 -n http://localhost:8848 --mcp-only
    $0 -n http://localhost:8848 -o ingress.yaml

EOF
}

# 解析参数
NACOS_URL="${DEFAULT_NACOS_URL}"
DOMAIN="${DEFAULT_DOMAIN}"
GROUP="${DEFAULT_GROUP}"
NAMESPACE=""
OUTPUT=""
DRY_RUN=false
MCP_ONLY=false
INGRESS_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -n|--nacos)
            NACOS_URL="$2"
            shift 2
            ;;
        -d|--domain)
            DOMAIN="$2"
            shift 2
            ;;
        -g|--group)
            GROUP="$2"
            shift 2
            ;;
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT="$2"
            shift 2
            ;;
        --mcp-only)
            MCP_ONLY=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --ingress-only)
            INGRESS_ONLY=true
            shift
            ;;
        *)
            echo "未知选项: $1"
            show_help
            exit 1
            ;;
    esac
done

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_SCRIPT="${SCRIPT_DIR}/generate_ingress_from_nacos.py"

# 检查 Python 脚本是否存在
if [[ ! -f "${PYTHON_SCRIPT}" ]]; then
    echo "错误: 找不到 Python 脚本: ${PYTHON_SCRIPT}"
    exit 1
fi

# 构建 Python 脚本参数（传递所有必需参数）
PYTHON_ARGS="-n ${NACOS_URL} -d ${DOMAIN} -g ${GROUP}"

if [[ -n "${NAMESPACE}" ]]; then
    PYTHON_ARGS="${PYTHON_ARGS} --namespace ${NAMESPACE}"
fi

if [[ -n "${OUTPUT}" ]]; then
    PYTHON_ARGS="${PYTHON_ARGS} -o ${OUTPUT}"
fi

if [[ "${DRY_RUN}" == true ]]; then
    PYTHON_ARGS="${PYTHON_ARGS} --dry-run"
fi

if [[ "${MCP_ONLY}" == true ]]; then
    PYTHON_ARGS="${PYTHON_ARGS} --mcp-only"
fi

if [[ "${INGRESS_ONLY}" == true ]]; then
    PYTHON_ARGS="${PYTHON_ARGS} --ingress-only"
fi

# 检查 kubectl 可用性（dry-run 模式下跳过）
if [[ "${DRY_RUN}" == false ]]; then
    check_kubectl
fi

# 调用 Python 脚本
python3 "${PYTHON_SCRIPT}" ${PYTHON_ARGS}
