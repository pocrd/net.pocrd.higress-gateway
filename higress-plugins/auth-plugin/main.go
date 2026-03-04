package main

import (
	"strings"

	"github.com/alibaba/higress/plugins/wasm-go/pkg/wrapper"
	"github.com/higress-group/proxy-wasm-go-sdk/proxywasm"
	"github.com/higress-group/proxy-wasm-go-sdk/proxywasm/types"
	"github.com/tidwall/gjson"
)

func main() {
	wrapper.SetCtx(
		"poc-auth-plugin",
		wrapper.ParseConfigBy(parseConfig),
		wrapper.ProcessRequestHeadersBy(onHttpRequestHeaders),
	)
}

type AuthConfig struct {
	// 可以在控制台动态配置这些参数
	EnabledOptionalCert bool `json:"enabled_optional_cert"`
}

func parseConfig(json gjson.Result, config *AuthConfig, log wrapper.Log) error {
	config.EnabledOptionalCert = json.Get("enabled_optional_cert").Bool()
	return nil
}

func onHttpRequestHeaders(ctx wrapper.HttpContext, config AuthConfig, log wrapper.Log) types.Action {
	// --- 1. 设备级别：证书 CN 提取 ---
	xfcc, _ := proxywasm.GetHttpRequestHeader("x-forwarded-client-cert")
	if xfcc != "" {
		cn := extractField(xfcc, "CN=")
		if cn != "" {
			log.Infof("Device Authenticated: CN=%s", cn)
			proxywasm.ReplaceHttpRequestHeader("x-dubbo-device-id", cn)
		}
	}

	// --- 2. 企业级别：合作伙伴签名 (演示逻辑) ---
	partnerID, _ := proxywasm.GetHttpRequestHeader("X-Partner-Id")
	if partnerID != "" {
		// 这里可以调用内部函数进行签名校验
		proxywasm.ReplaceHttpRequestHeader("x-dubbo-partner-id", partnerID)
	}

	// --- 3. 用户级别：Token 提取 ---
	authHeader, _ := proxywasm.GetHttpRequestHeader("Authorization")
	if strings.HasPrefix(authHeader, "Bearer ") {
		_ = authHeader[7:]
		// 简单演示：透传 Token 给后端 Dubbo 校验，或在此处解析 JWT
		proxywasm.ReplaceHttpRequestHeader("x-dubbo-user-id", "parsed-from-token")
	}

	return types.ActionContinue
}

// 辅助函数：解析 XFCC 中的字段
func extractField(xfcc, field string) string {
	if !strings.Contains(xfcc, field) {
		return ""
	}
	start := strings.Index(xfcc, field) + len(field)
	end := strings.Index(xfcc[start:], ";")
	if end == -1 {
		end = strings.Index(xfcc[start:], ",")
	}
	if end == -1 {
		end = len(xfcc[start:])
	}
	return strings.Trim(xfcc[start:start+end], "\" ")
}