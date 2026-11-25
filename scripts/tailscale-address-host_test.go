//go:build with_gvisor && !no_tailscale

package outbound

import (
	"net/netip"
	"testing"

	C "github.com/metacubex/mihomo/constant"
)

func TestArkClashTailscaleTCPAddress(t *testing.T) {
	ip4 := netip.MustParseAddr("100.64.0.1")
	ip6 := netip.MustParseAddr("fd7a:115c:a1e0::1")
	const domain = "peer.example.test"
	for _, tc := range []struct {
		name     string
		metadata C.Metadata
		want     string
	}{
		{"mapped IPv4", C.Metadata{DNSMode: C.DNSMapping, DstIP: ip4, Host: domain}, "100.64.0.1:443"},
		{"mapped IPv6", C.Metadata{DNSMode: C.DNSMapping, DstIP: ip6, Host: domain}, "[fd7a:115c:a1e0::1]:443"},
		{"mapping without IP", C.Metadata{DNSMode: C.DNSMapping, Host: domain}, domain + ":443"},
		{"explicit domain", C.Metadata{DNSMode: C.DNSNormal, DstIP: ip4, Host: domain}, domain + ":443"},
		{"fake IP", C.Metadata{DNSMode: C.DNSFakeIP, Host: domain}, domain + ":443"},
		{"hosts entry", C.Metadata{DNSMode: C.DNSHosts, DstIP: ip4, Host: domain}, domain + ":443"},
		{"sniffed rule only", C.Metadata{DNSMode: C.DNSNormal, DstIP: ip4, SniffHost: domain}, "100.64.0.1:443"},
		{"sniffed override", C.Metadata{DNSMode: C.DNSNormal, Host: domain, SniffHost: domain}, domain + ":443"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tc.metadata.DstPort = 443
			host, ip := tc.metadata.Host, tc.metadata.DstIP
			if got := tailscaleTCPAddress(&tc.metadata); got != tc.want {
				t.Errorf("address = %q, want %q", got, tc.want)
			}
			if tc.metadata.Host != host || tc.metadata.DstIP != ip {
				t.Error("dial changed routing metadata")
			}
		})
	}
}
