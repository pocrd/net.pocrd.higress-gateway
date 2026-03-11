#!/bin/bash

# Nacos 服务查询脚本
NACOS_HOST="localhost"
NACOS_HTTP_PORT="30848"

echo "=== Nacos 服务列表 ==="
curl -s "http://${NACOS_HOST}:${NACOS_HTTP_PORT}/nacos/v1/ns/service/list?groupName=PUBLIC-GROUP&pageNo=1&pageSize=10" | python3 -m json.tool 2>/dev/null || echo "查询失败"

echo ""
echo "=== Dubbo 服务详情 ==="
curl -s "http://${NACOS_HOST}:${NACOS_HTTP_PORT}/nacos/v1/ns/instance/list?serviceName=providers:com.pocrd.service_demo.api.GreeterServiceHttpExport:1.0.0:public&groupName=PUBLIC-GROUP" | python3 -m json.tool 2>/dev/null || echo "查询失败"

echo ""
echo "=== Nacos 健康状态 ==="
curl -s "http://${NACOS_HOST}:${NACOS_HTTP_PORT}/nacos/v1/ns/operator/metrics" | python3 -m json.tool 2>/dev/null || echo "查询失败"
