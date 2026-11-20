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
	stored, err := readGeneralSettings(opts.HomeDir)
	if err != nil || stored.Revision != next.Revision || stored.DelayTimeout != 1000 || stored.UserAgent != next.UserAgent {
		t.Fatal("settings were not persisted")
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
