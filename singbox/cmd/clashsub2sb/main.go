// clashsub2sb: Clash Meta subscription YAML → sing-box local provider JSON.
// Built for device-side update-providers.sh (linux/arm64). Only vmess is
// converted (matches convert.convert_proxy); info sinks (127.0.0.1) are dropped.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

type clashDoc struct {
	Proxies []map[string]any `yaml:"proxies"`
}

func main() {
	in := "/dev/stdin"
	outPath := ""
	args := os.Args[1:]
	if len(args) >= 1 {
		in = args[0]
	}
	if len(args) >= 2 {
		outPath = args[1]
	}
	raw, err := os.ReadFile(in)
	if err != nil {
		fatal(err)
	}
	var doc clashDoc
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		fatal(err)
	}
	outs := make([]map[string]any, 0, len(doc.Proxies))
	for _, p := range doc.Proxies {
		o, skip := convertProxy(p)
		if skip || o == nil {
			continue
		}
		outs = append(outs, o)
	}
	payload, err := json.MarshalIndent(map[string]any{"outbounds": outs}, "", "  ")
	if err != nil {
		fatal(err)
	}
	payload = append(payload, '\n')
	if outPath == "" {
		_, _ = os.Stdout.Write(payload)
		return
	}
	if err := os.WriteFile(outPath, payload, 0o644); err != nil {
		fatal(err)
	}
	fmt.Fprintf(os.Stderr, "wrote %d outbounds -> %s\n", len(outs), outPath)
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}

func convertProxy(p map[string]any) (map[string]any, bool) {
	name, _ := p["name"].(string)
	typ, _ := p["type"].(string)
	server, _ := p["server"].(string)
	if server == "127.0.0.1" || server == "0.0.0.0" {
		return nil, true
	}
	if strings.Contains(name, "官网") || strings.Contains(name, "关闭VPN") || strings.Contains(name, "更新订阅") {
		return nil, true
	}
	if strings.HasPrefix(name, "-----") {
		return nil, true
	}
	if typ != "vmess" {
		return nil, true
	}
	port := asInt(p["port"])
	uuid, _ := p["uuid"].(string)
	if name == "" || server == "" || uuid == "" || port == 0 {
		return nil, true
	}
	out := map[string]any{
		"type":        "vmess",
		"tag":         name,
		"server":      server,
		"server_port": port,
		"uuid":        uuid,
		"security":    strOr(p["cipher"], "auto"),
		"alter_id":    asInt(p["alterId"]),
	}
	if truthy(p["tls"]) {
		tls := map[string]any{"enabled": true}
		if sni := firstString(p["servername"], p["sni"]); sni != "" {
			tls["server_name"] = sni
		}
		if truthy(p["skip-cert-verify"]) {
			tls["insecure"] = true
		}
		out["tls"] = tls
	}
	network := strings.ToLower(strOr(p["network"], "tcp"))
	if network == "ws" {
		opts, _ := p["ws-opts"].(map[string]any)
		if opts == nil {
			opts = map[string]any{}
		}
		transport := map[string]any{
			"type": "ws",
			"path": strOr(opts["path"], "/"),
		}
		if hdr, ok := opts["headers"].(map[string]any); ok && len(hdr) > 0 {
			h := map[string]string{}
			for k, v := range hdr {
				h[k] = fmt.Sprint(v)
			}
			transport["headers"] = h
		}
		out["transport"] = transport
	} else if network != "tcp" && network != "" {
		return nil, true
	}
	return out, false
}

func asInt(v any) int {
	switch t := v.(type) {
	case int:
		return t
	case int64:
		return int(t)
	case float64:
		return int(t)
	case string:
		n, _ := strconv.Atoi(t)
		return n
	default:
		return 0
	}
}

func strOr(v any, def string) string {
	if s, ok := v.(string); ok && s != "" {
		return s
	}
	return def
}

func firstString(vals ...any) string {
	for _, v := range vals {
		if s, ok := v.(string); ok && s != "" {
			return s
		}
	}
	return ""
}

func truthy(v any) bool {
	switch t := v.(type) {
	case bool:
		return t
	case string:
		return t == "true" || t == "1" || strings.EqualFold(t, "yes")
	case int, int64, float64:
		return asInt(v) != 0
	default:
		return false
	}
}
