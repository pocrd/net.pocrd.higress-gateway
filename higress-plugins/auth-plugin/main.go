package main

import (
	"strings"

	"github.com/higress-group/proxy-wasm-go-sdk/proxywasm"
	"github.com/higress-group/proxy-wasm-go-sdk/proxywasm/types"
	"github.com/higress-group/wasm-go/pkg/log"
	"github.com/higress-group/wasm-go/pkg/wrapper"
	"github.com/tidwall/gjson"
)

func main() {}

func init() {
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

func parseConfig(json gjson.Result, config *AuthConfig, log log.Log) error {
	config.EnabledOptionalCert = json.Get("enabled_optional_cert").Bool()
	return nil
}

func onHttpRequestHeaders(ctx wrapper.HttpContext, config AuthConfig, log log.Log) types.Action {
	path, _ := proxywasm.GetHttpRequestHeader(":path")
	log.Warnf("[auth] path=%s", path)

	// --- 1. 设备级别：证书 CN 提取 ---
	xfcc, _ := proxywasm.GetHttpRequestHeader("x-forwarded-client-cert")
	if xfcc != "" {
		cn := extractField(xfcc, "CN=")
		if cn != "" {
			log.Warnf("[auth] device=%s", cn)
			proxywasm.ReplaceHttpRequestHeader("x-dubbo-device-id", cn)
		}
	}

	// --- 2. 企业级别：合作伙伴签名 ---
	partnerID, _ := proxywasm.GetHttpRequestHeader("X-Partner-Id")
	if partnerID != "" {
		log.Warnf("[auth] partner=%s", partnerID)
		proxywasm.ReplaceHttpRequestHeader("x-dubbo-partner-id", partnerID)
	}

	// --- 3. 用户级别：Token 提取 ---
	authHeader, _ := proxywasm.GetHttpRequestHeader("Authorization")
	if strings.HasPrefix(authHeader, "Bearer ") {
		log.Warnf("[auth] token=ok")
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