#!/bin/bash

# =================================================================
# Higress WASM 插件部署脚本
# 一键完成：编译插件 → 生成配置 → 重启服务
# =================================================================

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "========================================"
echo "    Higress WASM 插件部署工具"
echo "========================================"
echo ""

# 步骤1：编译插件
echo -e "${YELLOW}[1/3] 编译 WASM 插件...${NC}"
if [ -f "./build-wasm.sh" ]; then
    ./build-wasm.sh
else
    echo -e "${RED}错误: 找不到 build-wasm.sh 脚本${NC}"
    exit 1
fi

echo ""

# 步骤2：复制配置文件
echo -e "${YELLOW}[2/3] 部署配置文件...${NC}"

# 复制 McpBridge 配置（Nacos 服务发现）
if [ -d "config/mcpbridges" ]; then
    mkdir -p higress-data/mcpbridges
    cp config/mcpbridges/*.yaml higress-data/mcpbridges/ 2>/dev/null || true
    echo "  已复制 McpBridge 配置"
fi

# 复制 Ingress 配置（通过 McpBridge 动态引用 Nacos 服务）
if [ -d "config/ingresses" ]; then
    mkdir -p higress-data/ingresses
    cp config/ingresses/*.yaml higress-data/ingresses/ 2>/dev/null || true
    echo "  已复制 Ingress 配置"
fi

# 复制 WasmPlugin 配置到 wasmplugins 目录
if [ -d "config/wasmplugins" ]; then
    mkdir -p higress-data/wasmplugins
    cp config/wasmplugins/*.{yaml,wasm} higress-data/wasmplugins/ 2>/dev/null || true
    echo "  已复制 WasmPlugin 配置"
fi

# 显示插件配置
CONFIG_DIR="higress-data/wasmplugins"
if [ -d "${CONFIG_DIR}" ]; then
    echo "  插件配置目录: ${CONFIG_DIR}"
    for yaml_file in ${CONFIG_DIR}/*.yaml; do
        if [ -f "${yaml_file}" ]; then
            plugin_name=$(basename "${yaml_file}" .yaml)
            echo "    - ${plugin_name}"
        fi
    done
else
    echo -e "${RED}警告: 未找到 ${CONFIG_DIR} 目录${NC}"
fi

echo ""

# 步骤3：重启 Higress 服务
echo -e "${YELLOW}[3/3] 重启 Higress 服务...${NC}"
if command -v docker-compose &> /dev/null; then
    COMPOSE_CMD="docker-compose"
elif command -v docker &> /dev/null && docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
else
    echo -e "${RED}错误: 未找到 docker-compose 或 docker compose${NC}"
    exit 1
fi

echo "  停止现有服务..."
${COMPOSE_CMD} down

echo "  启动服务..."
${COMPOSE_CMD} up -d

echo ""
echo "  等待服务启动..."
sleep 5

# 检查服务状态
echo "  检查服务状态..."
if docker ps | grep -q "higress-gateway"; then
    echo -e "  ${GREEN}Higress 网关运行正常${NC}"
else
    echo -e "  ${RED}Higress 网关启动失败，请检查日志${NC}"
    docker logs higress-gateway --tail 20
    exit 1
fi

echo ""
echo "========================================"
echo -e "${GREEN}部署完成！${NC}"
echo "========================================"
echo ""
echo "访问地址:"
echo "  - Higress 控制台: http://localhost:8001"
echo "  - 网关地址: http://localhost"
echo ""
echo "查看日志:"
echo "  docker logs -f higress-gateway"
echo ""
