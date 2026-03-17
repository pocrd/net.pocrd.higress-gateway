#!/bin/bash

# ==================== 配置参数 ====================
DEVICE_MAC="AA:BB:CC:DD:EE:FF"  # 替换为实际 MAC 地址
SERVER_URL="https://xz.caringfamily.cn"
CLIENT_CERT="../certs/files/bagua/testFactory/devices/device003/device003-fullchain.crt"    # 客户端证书
CLIENT_KEY="../certs/files/bagua/testFactory/devices/device003/device003.key"      # 客户端私钥

echo "======================================"
echo "OTA 激活流程测试"
echo "设备 MAC: ${DEVICE_MAC}"
echo "======================================"

# ==================== 步骤 1: 检查激活状态 ====================
echo -e "\n[步骤 1] 检查设备激活状态..."
ACTIVATE_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${SERVER_URL}/api/device/ota/activate" \
  -H "Content-Type: application/json" \
  --cert "${CLIENT_CERT}" \
  --key "${CLIENT_KEY}")

ACTIVATE_BODY=$(echo "${ACTIVATE_RESPONSE}" | sed '$d')
ACTIVATE_CODE=$(echo "${ACTIVATE_RESPONSE}" | tail -n 1)

echo "HTTP 状态码：${ACTIVATE_CODE}"
echo "响应内容：${ACTIVATE_BODY}"

if [ "${ACTIVATE_CODE}" == "200" ]; then
    echo "✅ 设备已激活，跳过注册步骤"
elif [ "${ACTIVATE_CODE}" == "202" ]; then
    echo "⚠️  设备未激活，开始注册..."
    
    # ==================== 步骤 2: 注册设备 ====================
    echo -e "\n[步骤 2] 注册设备..."
    REGISTER_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${SERVER_URL}/api/device/ota" \
      -H "Content-Type: application/json" \
      --cert "${CLIENT_CERT}" \
      --key "${CLIENT_KEY}" \
      -d "{
        \"mac_address\": \"${DEVICE_MAC}\",
        \"chip_model_name\": \"ESP32-S3\",
        \"application\": {
          \"version\": \"1.0.0\"
        },
        \"board\": {
          \"ssid\": \"TestWiFi\",
          \"type\": \"esp32\"
        }
      }")
    
    REGISTER_BODY=$(echo "${REGISTER_RESPONSE}" | sed '$d')
    REGISTER_CODE=$(echo "${REGISTER_RESPONSE}" | tail -n 1)
    
    echo "HTTP 状态码：${REGISTER_CODE}"
    echo "响应内容：${REGISTER_BODY}"
    
    if [ "${REGISTER_CODE}" == "200" ]; then
        echo "✅ 设备注册成功"
    else
        echo "❌ 设备注册失败"
        exit 1
    fi
else
    echo "❌ 检查激活状态失败，HTTP 码：${ACTIVATE_CODE}"
    exit 1
fi

# ==================== 步骤 3: 获取固件信息 ====================
echo -e "\n[步骤 3] 获取固件信息..."
FIRMWARE_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${SERVER_URL}/api/device/ota" \
  -H "Content-Type: application/json" \
  -H "x-dubbo-device-id: device9999" \
  --cert "${CLIENT_CERT}" \
  --key "${CLIENT_KEY}" \
  -d "{
    \"mac_address\": \"${DEVICE_MAC}\",
    \"chip_model_name\": \"ESP32-S3\",
    \"application\": {
      \"version\": \"1.0.0\"
    },
    \"board\": {
      \"ssid\": \"TestWiFi\",
      \"type\": \"esp32\"
    }
  }")

FIRMWARE_BODY=$(echo "${FIRMWARE_RESPONSE}" | sed '$d')
FIRMWARE_CODE=$(echo "${FIRMWARE_RESPONSE}" | tail -n 1)

echo "HTTP 状态码：${FIRMWARE_CODE}"
echo "响应内容：${FIRMWARE_BODY}"

echo -e "\n======================================"
echo "OTA 流程完成"
echo "======================================"

