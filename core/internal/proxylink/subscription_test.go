package proxylink

import (
	"encoding/base64"
	"strings"
	"testing"

	"go.yaml.in/yaml/v3"
)

func TestSubscriptionProfile(t *testing.T) {
	links := strings.Join([]string{
		"vless://33333333-3333-4333-8333-333333333333@192.0.2.50:443?security=reality&pbk=key&sid=ab&fp=chrome&sni=example.com#节点",
		"trojan://secret@192.0.2.51:443?sni=example.com#节点",
		"ss://YWVzLTEyOC1nY206c2VjcmV0@192.0.2.52:8388#DIRECT",
		"ss://YWVzLTEyOC1nY206c2VjcmV0@192.0.2.53:8388",
	}, "\n")
	for _, input := range []string{links, base64.StdEncoding.EncodeToString([]byte(links)) + "\n"} {
		out, ok := SubscriptionProfile([]byte(input))
		if !ok {
			t.Fatal("分享链接订阅未转换")
		}
		var doc struct {
			Proxies []map[string]any `yaml:"proxies"`
			Groups  []struct {
				Name    string   `yaml:"name"`
				Type    string   `yaml:"type"`
				Proxies []string `yaml:"proxies"`
			} `yaml:"proxy-groups"`
			Rules []string `yaml:"rules"`
		}
		if err := yaml.Unmarshal(out, &doc); err != nil {
			t.Fatal(err)
		}
		want := []string{"节点", "节点-01", "DIRECT-01", "192.0.2.53"}
		if len(doc.Proxies) != len(want) || len(doc.Groups) != 1 || strings.Join(doc.Groups[0].Proxies, ",") != strings.Join(want, ",") {
			t.Fatalf("转换结果不符：%s", out)
		}
		for i, proxy := range doc.Proxies {
			if proxy["name"] != want[i] {
				t.Fatalf("第 %d 个节点名 %v，期望 %s", i, proxy["name"], want[i])
			}
		}
		if doc.Groups[0].Name != "PROXY" || doc.Groups[0].Type != "select" || strings.Join(doc.Rules, ",") != "MATCH,PROXY" {
			t.Fatalf("代理组或规则不符：%s", out)
		}
	}
}

func TestSubscriptionProfileLeavesClashAlone(t *testing.T) {
	for _, input := range []string{
		"# https://example.com\nproxies:\n  - {name: a, type: ss}\n",
		"mixed-port: 7890\nproxies: []\n",
		"",
		"bm90IGEgbGluaw==",
	} {
		if _, ok := SubscriptionProfile([]byte(input)); ok {
			t.Fatalf("%q 不应转换", input)
		}
	}
}
