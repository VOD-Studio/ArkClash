package diagnostics

import (
	"strings"
	"testing"

	"github.com/metacubex/mihomo/log"
)

func TestDiagnosticLogDescriptionsOnlyUseKnownTemplatesAndCauses(t *testing.T) {
	const dialTemplate = "[%s] dial %s %s --> %s error: %s"
	const dialMatchTemplate = "[%s] dial %s (match %s/%s) %s --> %s error: %s"
	const routeMatchTemplate = "[%s] %s --> %s match %s using %s"
	const routeDirectTemplate = "[%s] %s --> %s using DIRECT"

	// 结构化路由与拨号失败解析。
	routeGot := DescribeLog(log.Event{
		Template: routeMatchTemplate,
		Payload:  "[TCP] 198.18.0.1:54321(proc, uid=100) --> www.example.com:443 match DOMAIN-SUFFIX(example.com) using Proxy[HK-01]",
	})
	if routeGot.Event != "route_selected" || routeGot.Tag != "TCP" || routeGot.Target != "www.example.com:443" ||
		routeGot.Rule != "DOMAIN-SUFFIX(example.com)" || routeGot.Proxy != "Proxy[HK-01]" ||
		routeGot.Source != "198.18.0.1:54321" || strings.Contains(routeGot.Message, "uid=100") {
		t.Fatalf("unexpected structured route log: %+v", routeGot)
	}

	directGot := DescribeLog(log.Event{
		Template: routeDirectTemplate,
		Payload:  "[UDP] 198.18.0.1:53000 --> 223.5.5.5:53 using DIRECT",
	})
	if directGot.Event != "route_direct" || directGot.Tag != "UDP" || directGot.Target != "223.5.5.5:53" ||
		directGot.Proxy != "DIRECT" || directGot.Source != "198.18.0.1:53000" {
		t.Fatalf("unexpected direct route log: %+v", directGot)
	}

	dialGot := DescribeLog(log.Event{
		Template: dialMatchTemplate,
		Payload:  "[TCP] dial Proxy (match DOMAIN-SUFFIX/example.com) 198.18.0.1:54321 --> www.example.com:443 error: dial tcp 203.0.113.10:443: connect: connection refused",
	})
	if dialGot.Event != "dial_failed" || dialGot.Tag != "TCP" || dialGot.Proxy != "Proxy" ||
		dialGot.Rule != "DOMAIN-SUFFIX(example.com)" || dialGot.Target != "www.example.com:443" ||
		dialGot.Reason != "connection refused" || strings.Contains(dialGot.Detail, "203.0.113.10") ||
		strings.Contains(dialGot.Message, "203.0.113.10") {
		t.Fatalf("unexpected dial failure log: %+v", dialGot)
	}

	// DNS 结构化解析与上游 DoH 凭据/路径脱敏。
	dnsQueryGot := DescribeLog(log.Event{
		Template: "[DNS] resolve %s %s from %s",
		Payload:  "[DNS] resolve api.example.com AAAA from https://user:pass@dns.example.net/secret-id?token=abc",
	})
	if dnsQueryGot.Event != "dns_query" || dnsQueryGot.Tag != "DNS" || dnsQueryGot.Target != "api.example.com" ||
		strings.Contains(dnsQueryGot.Detail, "pass") || strings.Contains(dnsQueryGot.Detail, "secret-id") ||
		strings.Contains(dnsQueryGot.Detail, "abc") || !strings.Contains(dnsQueryGot.Detail, "https://dns.example.net/…") {
		t.Fatalf("unexpected dns query log: %+v", dnsQueryGot)
	}

	sniffGot := DescribeLog(log.Event{
		Template: "[Sniffer] Sniff %s [%s]-->[%s] success, replace domain [%s]-->[%s]",
		Payload:  "[Sniffer] Sniff tls [172.19.0.1:43852]-->[1.2.3.4:443] success, replace domain [1.2.3.4]-->[api.example.com]",
	})
	if sniffGot.Event != "sniffer" || sniffGot.Tag != "Sniffer" || sniffGot.Target != "api.example.com" ||
		sniffGot.Source != "172.19.0.1:43852" || !strings.Contains(sniffGot.Detail, "tls") {
		t.Fatalf("unexpected sniffer log: %+v", sniffGot)
	}

	hopGot := DescribeLog(log.Event{
		Template: "Hopped to 203.0.113.10:34567",
		Payload:  "Hopped to 203.0.113.10:34567",
	})
	if hopGot.Event != "port_hop" || hopGot.Tag != "QUIC" || strings.Contains(hopGot.Message, "203.0.113.10") {
		t.Fatalf("unexpected port hop log: %+v", hopGot)
	}

	// 组件动态日志脱敏：保留诊断语义，遮蔽链接、凭据、私钥和裸地址，不误伤 HH:MM:SS 时间。
	wgGot := DescribeLog(log.Event{
		Template: "[WG](secret-node) created wireguard ipc conf: \n private_key=ABCDEF123456\nendpoint=1.2.3.4:51820",
		Payload:  "[WG](secret-node) created wireguard ipc conf: \n private_key=ABCDEF123456\nendpoint=1.2.3.4:51820",
	})
	if wgGot.Event != "component" || wgGot.Tag != "WG" || strings.Contains(wgGot.Message, "ABCDEF") ||
		strings.Contains(wgGot.Message, "secret-node") || strings.Contains(wgGot.Message, "1.2.3.4") {
		t.Fatalf("wireguard ipc conf leaked: %+v", wgGot)
	}

	compGot := DescribeLog(log.Event{
		Template: "dynamic",
		Payload:  "[TUN] read packet from 198.18.0.1:52341 to [2001:db8::1]:443 at 20:05:12 via https://u:p@sub.example/path?token=xyz Bearer supersecret",
	})
	if compGot.Event != "component" || compGot.Tag != "TUN" ||
		strings.Contains(compGot.Message, "198.18.0.1") || strings.Contains(compGot.Message, "2001:db8") ||
		strings.Contains(compGot.Message, "sub.example") || strings.Contains(compGot.Message, "supersecret") ||
		!strings.Contains(compGot.Message, "20:05:12") {
		t.Fatalf("component log redaction failed: %+v", compGot)
	}

	// 畸形路由/拨号载荷走安全回退，不回显原始文本。
	for _, item := range []struct{ template, payload, event, reason string }{
		{routeMatchTemplate, "private node and endpoint", "route_selected", ""},
		{"[DNS] hijack udp:%s from %s", "private endpoints", "dns_udp", ""},
		{"[Rule] use default rules", "", "default_rules", ""},
		{"[Rule] rematch proxy %s update metadata to rematch-name=%q sub-rule=%q", "private settings", "template", ""},
		{dialTemplate, "[TCP] dial timeout-node private error: connect: connection refused", "dial_failed", "connection refused"},
		{dialTemplate, "[TCP] dial private error: context deadline exceeded", "dial_failed", "timeout"},
		{dialTemplate, "[TCP] dial private error: x509: certificate has expired", "dial_failed", "certificate"},
		{dialTemplate, "[TCP] dial timeout-node private error: EOF", "dial_failed", "dial error"},
	} {
		got := DescribeLog(log.Event{Template: item.template, Payload: item.payload})
		if got.Event != item.event || got.Reason != item.reason ||
			strings.Contains(got.Message, "private") || strings.Contains(got.Message, "timeout-node") {
			t.Fatalf("unexpected fallback classification for %s: %+v", item.event, got)
		}
	}
}
