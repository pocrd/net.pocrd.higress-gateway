package main

import (
	"strings"

	"github.com/higress-group/proxy-wasm-go-sdk/proxywasm"
	"github.com/higress-group/proxy-wasm-go-sdk/proxywasm/types"
	"github.com/higress-group/wasm-go/pkg/wrapper"
	"github.com/tidwall/gjson"
)

func main() {}

func init() {
	wrapper.SetCtx(
		"poc-auth-plugin",
		wrapper.ParseConfig[AuthConfig](parseConfig),
		wrapper.ProcessRequestHeaders[AuthConfig](onHttpRequestHeaders),
	)
}

type AuthConfig struct {
	// 可以在控制台动态配置这些参数
	EnabledOptionalCert bool `json:"enabled_optional_cert"`
}

func parseConfig(json gjson.Result, config *AuthConfig) error {
	config.EnabledOptionalCert = json.Get("enabled_optional_cert").Bool()
	return nil
}

func onHttpRequestHeaders(ctx wrapper.HttpContext, config AuthConfig) types.Action {
	// --- 1. 设备级别：证书 CN 提取 ---
	//从 XFCC (x-forwarded-client-cert) 头提取客户端证书信息
	xfcc, _ := proxywasm.GetHttpRequestHeader("x-forwarded-client-cert")
	if xfcc != "" {
		cn := extractField(xfcc, "CN=")
		if cn != "" {
			proxywasm.ReplaceHttpRequestHeader("x-dubbo-device-id", cn)
		}
	}

	// --- 2. 用户级别：Token 提取 ---
	authHeader, _ := proxywasm.GetHttpRequestHeader("Authorization")
	if strings.HasPrefix(authHeader, "Bearer ") {
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
	// XFCC 中的逗号可能被 URL 编码为 %2C
	// 先尝试找普通逗号
	end := strings.Index(xfcc[start:], ",")
	// 再找 URL 编码的逗号 %2C
	if end == -1 {
		end = strings.Index(xfcc[start:], "%2C")
	}
	// 再找分号
	if end == -1 {
		end = strings.Index(xfcc[start:], ";")
	}
	// 再找双引号结束
	if end == -1 {
		end = strings.Index(xfcc[start:], "\"")
	}
	if end == -1 {
		end = len(xfcc[start:])
	}
	return strings.Trim(xfcc[start:start+end], "\" ")
}
