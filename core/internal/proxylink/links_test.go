package proxylink

import (
	"fmt"
	"strings"
	"testing"
)

func TestHTTPUpgradeShareLinkRoundTrip(t *testing.T) {
	for _, tt := range []struct {
		protocol string
		alterID  int
		fastOpen bool
	}{
		{"vless", 0, false},
		{"vless", 0, true},
		{"vmess", 0, true},
		{"vmess", 4, true},
		{"trojan", 0, false},
	} {
		t.Run(tt.protocol+":"+fmt.Sprint(tt.alterID, "/", tt.fastOpen), func(t *testing.T) {
			const path = "/upgrade?token=fixture"
			ws := map[string]any{"path": path, "v2ray-http-upgrade": true}
			if tt.fastOpen {
				ws["v2ray-http-upgrade-fast-open"] = true
			}
			if tt.protocol != "trojan" {
				ws["headers"] = map[string]any{"Host": "cdn.example.com"}
			}
			definition := map[string]any{
				"name": "fixture", "type": tt.protocol, "server": "192.0.2.50", "port": 443, "tls": true,
				"uuid": "33333333-3333-4333-8333-333333333333", "alterId": tt.alterID, "password": "fixture",
				"network": "ws", "ws-opts": ws,
			}
			link := Encode([]map[string]any{definition})[0]
			decoded := Decode(link)
			if len(decoded) != 1 || decoded[0]["network"] != "ws" {
				t.Fatal("分享链接未还原 WebSocket 传输")
			}
			opts := proxyFields(decoded[0]).sub("ws-opts")
			if !opts.flag("v2ray-http-upgrade") || opts.flag("v2ray-http-upgrade-fast-open") != tt.fastOpen ||
				opts.str("path") != path || opts.sub("headers").str("Host") != proxyFields(ws).sub("headers").str("Host") {
				t.Fatal("分享链接改变了 HTTPUpgrade 选项")
			}
		})
	}
}

func TestEncodeDecodeUnsupportedAndInvalid(t *testing.T) {
	links := Encode([]map[string]any{
		{"name": "示例", "type": "ss", "server": "192.0.2.50", "port": 443, "cipher": "aes-128-gcm", "password": "secret/+"},
		{"name": "直连", "type": "direct"},
	})
	if len(links) != 2 || !strings.HasPrefix(links[0], "ss://") || links[1] != "" {
		t.Fatalf("unexpected encoded links: %+v", links)
	}
	if decoded := Decode("vless://invalid"); len(decoded) != 0 {
		t.Fatalf("expected empty slice for invalid link, got %+v", decoded)
	}
}
