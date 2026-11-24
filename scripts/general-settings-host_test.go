package main

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/geodata"
	mihomoHttp "github.com/metacubex/mihomo/component/http"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/log"
)

func generalTestStart(t *testing.T) startOptions {
	t.Helper()
	opts := lifecycleOptions(t)
	opts.Profile = "general"
	opts.ConfigPath = lifecycleWriteProfile(t, opts, opts.Profile, lifecycleProfile)
	if err := start(opts); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = stop() })
	return opts
}

func saveGeneralTestSettings(settings generalSettings) error {
	return updateGeneralSettings(profileSettingsRequest[generalSettings]{BootID: runtimeBootID,
		ExpectedRevision: current.General.Revision, Settings: settings})
}

func reserveGeneralPort(t *testing.T) net.Listener {
	t.Helper()
	for port := 48999; port > 48899; port-- {
		if listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port)); err == nil {
			return listener
		}
	}
	t.Fatal("no test ports")
	return nil
}

func TestGeneralSettingsApplyWithoutReplacingTun(t *testing.T) {
	opts := generalTestStart(t)
	target := reserveGeneralPort(t)
	defer target.Close()
	free := reserveGeneralPort(t)
	port := free.Addr().(*net.TCPAddr).Port
	free.Close()
	next := current.General
	next.Revision = "inbound-configured"
	next.Ports = &generalPorts{Mixed: port}
	next.Authentication = &generalAuthentication{Enabled: true, Username: "test-user", Password: "test-pass"}
	next.UserAgent = "ArkClash-Test"
	next.DelayTimeout = 1000
	if err := saveGeneralTestSettings(next); err != nil {
		t.Fatal(err)
	}
	inboundReachable(t, port, false)
	if err := attachTun(11, tunNetworkOptions{Stack: "gvisor", MTU: 1500, DNSHijacking: true}, hostAttachIdentity()); err != nil {
		t.Fatal(err)
	}
	tun := tunListener
	proxyStatus := func(credentials string) int {
		conn, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
		fmt.Fprintf(conn, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n%s\r\n", target.Addr(), target.Addr(), credentials)
		response, err := http.ReadResponse(bufio.NewReader(conn), &http.Request{Method: http.MethodConnect})
		if err != nil {
			t.Fatal(err)
		}
		return response.StatusCode
	}
	if status := proxyStatus(""); status != 407 {
		t.Fatalf("authentication required, got %d", status)
	}
	authorization := "Proxy-Authorization: Basic " + base64.StdEncoding.EncodeToString([]byte("test-user:test-pass")) + "\r\n"
	if status := proxyStatus(authorization); status != 200 {
		t.Fatalf("authenticated CONNECT got %d", status)
	}
	blocked := next
	blocked.Revision = "inbound-rejected"
	blocked.Ports = &generalPorts{Mixed: target.Addr().(*net.TCPAddr).Port}
	if err := saveGeneralTestSettings(blocked); !errors.Is(err, errGeneralPort) {
		t.Fatalf("expected bind conflict: %v", err)
	}
	inboundReachable(t, port, true)
	if tunListener != tun || current.General.Revision != "inbound-configured" {
		t.Fatal("conflict changed live configuration")
	}
	next.Revision = "hosts-configured"
	next.Hosts = map[string][]string{"general.test": {"192.0.2.21"}}
	if err := saveGeneralTestSettings(next); err != nil {
		t.Fatal(err)
	}
	if tunListener != tun {
		t.Fatal("Hosts update replaced platform TUN")
	}
	host, ok := resolver.DefaultHosts.Search("general.test", false)
	if !ok || host.IPs[0].String() != "192.0.2.21" {
		t.Fatal("Hosts setting did not reach resolver")
	}
	next.Revision = "ua-updated"
	next.UserAgent = "ArkClash-Test-v2"
	next.UserAgents = []string{"ArkClash-Test", "ArkClash-Test-v2"}
	if err := saveGeneralTestSettings(next); err != nil {
		t.Fatal(err)
	}
	if mihomoHttp.UA() != "ArkClash-Test-v2" {
		t.Fatalf("expected live UA ArkClash-Test-v2, got %q", mihomoHttp.UA())
	}
	stored, err := readGeneralSettings(opts.HomeDir)
	if err != nil || stored.Revision != next.Revision || stored.DelayTimeout != 1000 || stored.UserAgent != next.UserAgent ||
		strings.Join(stored.UserAgents, ",") != "ArkClash-Test,ArkClash-Test-v2" {
		t.Fatal("settings were not persisted")
	}
	next.Revision = "system-dns-enabled"
	next.AppendSystemDNS = true
	if err := saveGeneralTestSettings(next); err != nil {
		t.Fatal(err)
	}
	stored, err = readGeneralSettings(opts.HomeDir)
	if err != nil || !stored.AppendSystemDNS || tunListener != tun {
		t.Fatalf("could not persist system DNS without replacing the TUN: %v", err)
	}
}

func TestGeneralPanelControllerIsolationAndRotation(t *testing.T) {
	opts := generalTestStart(t)
	reserved := reserveGeneralPort(t)
	panel := reserved.Addr().String()
	port := reserved.Addr().(*net.TCPAddr).Port
	if err := changePanelControllerLocked(panel, "panel-key-one"); !errors.Is(err, errGeneralPanel) {
		reserved.Close()
		t.Fatalf("occupied panel port was accepted: %v", err)
	}
	reserved.Close()
	if err := changePanelControllerLocked(panel, "panel-key-one"); err != nil {
		t.Fatal(err)
	}
	client := &http.Client{Timeout: 2 * time.Second}
	code := func(address, path, secret string) int {
		req, err := http.NewRequest(http.MethodGet, "http://"+address+path, nil)
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("Authorization", "Bearer "+secret)
		response, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		return response.StatusCode
	}
	if code(panel, "/version", opts.Secret) != 401 ||
		code(panel, "/version", "panel-key-one") != 200 ||
		code(panel, "/arkclash/status", "panel-key-one") != 404 ||
		code(panel, "/logs", "panel-key-one") != 404 {
		t.Fatal("controller credentials or private routes crossed the boundary")
	}
	if err := changePanelControllerLocked(panel, "panel-key-two"); err != nil ||
		code(panel, "/version", "panel-key-one") != 401 ||
		code(panel, "/version", "panel-key-two") != 200 {
		t.Fatalf("panel key rotation failed: %v", err)
	}
	if err := changePanelControllerLocked(panel, ""); err != nil {
		t.Fatal(err)
	}
	inboundReachable(t, port, false)
	if code(opts.Controller, "/version", opts.Secret) != 200 {
		t.Fatal("disabling panel closed internal controller")
	}
}

func TestLogPageCaptureThresholdRedactionAndRetirement(t *testing.T) {
	generalTestStart(t)
	if _, status, _ := subscribeDiagnostics("logs", runtimeBootID, runtimeConfigRevision); status != 403 {
		t.Fatal("capture was enabled by default")
	}
	next := current.General
	next.Revision = "logs-on"
	next.CaptureLogs = true
	if err := saveGeneralTestSettings(next); err != nil {
		t.Fatal(err)
	}
	server := newDiagnosticStreamServer(t, nil)
	conn, reader, worker := dialDiagnosticStream(t, server, "logs", false)
	var frame diagnosticLogsFrame
	if err := json.Unmarshal(readDiagnosticWSFrame(t, conn, reader).Payload, &frame); err != nil ||
		frame.Kind != "snapshot" || len(frame.Logs) != 0 {
		t.Fatal("missing initial log snapshot")
	}
	log.Infoln("ignored level: %s", "unneeded")
	log.Errorln("download failed: %s", "https://secret.example/subscription?token=private")
	if err := json.Unmarshal(readDiagnosticWSFrame(t, conn, reader).Payload, &frame); err != nil ||
		frame.Kind != "delta" || len(frame.Logs) != 1 || frame.Logs[0].Level != "error" ||
		!strings.Contains(frame.Logs[0].Message, "download failed") || strings.Contains(frame.Logs[0].Message, "secret") {
		t.Fatal("log threshold or redaction failed")
	}
	closeDiagnosticClient(t, conn, reader)
	waitDiagnosticStream(t, worker.done)
	mu.Lock()
	collector := diagnosticLogs
	mu.Unlock()
	if collector != nil {
		t.Fatal("last log subscriber did not retire capture")
	}
}

func TestGeneralCoreOverridesApplyRestoreAndValidate(t *testing.T) {
	opts := lifecycleOptions(t)
	opts.Profile = "core-overrides"
	opts.ConfigPath = lifecycleWriteProfile(t, opts, opts.Profile, `mode: rule
log-level: silent
unified-delay: false
tcp-concurrent: false
ipv6: true
geodata-loader: standard
proxies: []
rules: ['MATCH,DIRECT']
`)
	if err := start(opts); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = stop() })
	if err := attachTun(12, tunNetworkOptions{Stack: "gvisor", MTU: 1500, DNSHijacking: true}, hostAttachIdentity()); err != nil {
		t.Fatal(err)
	}
	tun := tunListener
	if adapter.UnifiedDelay.Load() || dialer.GetTcpConcurrent() || resolver.DisableIPv6 || geodata.LoaderName() != "standard" {
		t.Fatalf("unexpected profile baseline: unified=%v tcp=%v disableIPv6=%v loader=%q",
			adapter.UnifiedDelay.Load(), dialer.GetTcpConcurrent(), resolver.DisableIPv6, geodata.LoaderName())
	}

	// 仅设置全局测速链接时，不应触发配置重建或更换 TUN。
	beforeRevision := runtimeConfigRevision
	testURL := "https://cp.cloudflare.com/generate_204"
	next := current.General
	next.Revision = "core-test-url"
	next.CoreOverrides = &generalCoreOverrides{TestURL: &testURL}
	if err := saveGeneralTestSettings(next); err != nil {
		t.Fatal(err)
	}
	if runtimeConfigRevision != beforeRevision || tunListener != tun {
		t.Fatalf("testUrl-only update rebuilt runtime: revision=%d->%d tunSame=%v",
			beforeRevision, runtimeConfigRevision, tunListener == tun)
	}

	// 逐项开启其余四项内核覆写：unified-delay、tcp-concurrent、ipv6、geodata-loader。
	yes, no := true, false
	memc := "memconservative"
	next.Revision = "core-all-on"
	next.CoreOverrides = &generalCoreOverrides{
		TestURL:       &testURL,
		UnifiedDelay:  &yes,
		TCPConcurrent: &yes,
		IPv6:          &no,
		GeodataLoader: &memc,
	}
	if err := saveGeneralTestSettings(next); err != nil {
		t.Fatal(err)
	}
	if tunListener != tun {
		t.Fatal("core overrides replaced platform TUN")
	}
	if !adapter.UnifiedDelay.Load() || !dialer.GetTcpConcurrent() || !resolver.DisableIPv6 || geodata.LoaderName() != "memconservative" {
		t.Fatalf("core overrides did not apply: unified=%v tcp=%v disableIPv6=%v loader=%q",
			adapter.UnifiedDelay.Load(), dialer.GetTcpConcurrent(), resolver.DisableIPv6, geodata.LoaderName())
	}

	// 移除覆写后恢复配置自身的值，同时保留磁盘持久化一致性。
	next.Revision = "core-cleared"
	next.CoreOverrides = nil
	if err := saveGeneralTestSettings(next); err != nil {
		t.Fatal(err)
	}
	if adapter.UnifiedDelay.Load() || dialer.GetTcpConcurrent() || resolver.DisableIPv6 || geodata.LoaderName() != "standard" {
		t.Fatalf("clearing core overrides did not restore profile values: unified=%v tcp=%v disableIPv6=%v loader=%q",
			adapter.UnifiedDelay.Load(), dialer.GetTcpConcurrent(), resolver.DisableIPv6, geodata.LoaderName())
	}
	stored, err := readGeneralSettings(opts.HomeDir)
	if err != nil || stored.CoreOverrides != nil {
		t.Fatalf("unexpected persisted overrides after clear: %+v err=%v", stored.CoreOverrides, err)
	}

	// 校验拒绝非法测速地址和非法 geodata-loader。
	for _, bad := range []*generalCoreOverrides{
		{TestURL: ptrString("")},
		{TestURL: ptrString("ftp://example.com/204")},
		{TestURL: ptrString("https://")},
		{GeodataLoader: ptrString("fast")},
	} {
		invalid := current.General
		invalid.Revision = "core-bad"
		invalid.CoreOverrides = bad
		if err := saveGeneralTestSettings(invalid); !errors.Is(err, errGeneralInvalid) {
			t.Fatalf("expected errGeneralInvalid for %+v, got %v", bad, err)
		}
	}
}

func ptrString(value string) *string { return &value }
