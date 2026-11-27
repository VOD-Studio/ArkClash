package api

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"testing"
	"time"

	"github.com/VOD-Studio/ArkClash/core/internal/engine"
)

func TestLifecycleControllerRetiresBeforeNextBoot(t *testing.T) {
	options := apiLifecycleOptions(t)
	client := &http.Client{Timeout: time.Second, Transport: &http.Transport{DisableKeepAlives: true}}
	defer client.CloseIdleConnections()
	defer testEng.Stop()
	previous := ""
	for i := range 20 {
		options.Secret = fmt.Sprintf("isolated-controller-%d", i)
		if err := testEng.Start(options); err != nil {
			t.Fatal(err)
		}
		for _, secret := range []string{options.Secret, previous} {
			if secret == "" {
				continue
			}
			request, err := http.NewRequest(http.MethodGet, "http://"+options.Controller+"/version", nil)
			if err != nil {
				t.Fatal(err)
			}
			request.Header.Set("Authorization", "Bearer "+secret)
			response, err := client.Do(request)
			if err != nil {
				t.Fatalf("boot %d controller unavailable: %v", i, err)
			}
			_, _ = io.Copy(io.Discard, response.Body)
			_ = response.Body.Close()
			want := http.StatusOK
			if secret == previous {
				want = http.StatusUnauthorized
			}
			if response.StatusCode != want {
				t.Fatalf("boot %d accepted wrong controller generation: %d", i, response.StatusCode)
			}
		}
		testEng.Stop()
		connection, err := net.DialTimeout("tcp", options.Controller, 100*time.Millisecond)
		if connection != nil {
			_ = connection.Close()
		}
		if err == nil {
			t.Fatalf("boot %d stop returned before controller closed", i)
		}
		previous = options.Secret
	}
}

func TestLifecycleFullStopClosesHijackedControllerStreams(t *testing.T) {
	options := apiLifecycleOptions(t)
	if err := testEng.Start(options); err != nil {
		t.Fatal(err)
	}
	defer testEng.Stop()
	stream, err := net.DialTimeout("tcp", options.Controller, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	if err := stream.SetDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	_, err = fmt.Fprintf(stream, "GET /traffic HTTP/1.1\r\nHost: %s\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: Zml4dHVyZS1zdHJlYW0xNg==\r\n\r\n", options.Controller)
	if err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(stream)
	response, err := http.ReadResponse(reader, &http.Request{Method: http.MethodGet})
	if err != nil || response.StatusCode != http.StatusSwitchingProtocols {
		t.Fatalf("stream did not upgrade: response=%v err=%v", response, err)
	}
	if err := testEng.Stop(); err != nil {
		t.Fatal(err)
	}
	// 升级后的 HTTP 连接已不归 http.Server.Close 管，必须由嵌入宿主显式退休。
	if _, err := io.Copy(io.Discard, reader); err != nil {
		t.Fatalf("retired stream stayed open or failed to close: %v", err)
	}
}

func TestLifecycleControllerServesArkClashStatusAndBlocksEmbedRoutes(t *testing.T) {
	options := apiLifecycleOptions(t)
	options.Secret = "arkclash-status-secret"

	client := &http.Client{Timeout: 2 * time.Second, Transport: &http.Transport{DisableKeepAlives: true}}
	defer client.CloseIdleConnections()

	checkRunning := func(secret string) string {
		t.Helper()
		// 有效凭据命中 /arkclash/status，返回当前 boot 快照。
		req, err := http.NewRequest(http.MethodGet, "http://"+options.Controller+"/arkclash/status", nil)
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("Authorization", "Bearer "+secret)
		resp, err := client.Do(req)
		if err != nil {
			t.Fatalf("status request failed: %v", err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("status code=%d, want 200", resp.StatusCode)
		}
		var got engine.StatusResponse
		if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
			t.Fatalf("decode status: %v", err)
		}
		want := testEng.Status()
		if !got.Running || got.BootID != want.BootID {
			t.Fatalf("status=%+v, want boot=%s running=true", got, want.BootID)
		}

		// 错误凭据必须被鉴权拒绝。
		badReq, err := http.NewRequest(http.MethodGet, "http://"+options.Controller+"/arkclash/status", nil)
		if err != nil {
			t.Fatal(err)
		}
		badReq.Header.Set("Authorization", "Bearer wrong-secret")
		badResp, err := client.Do(badReq)
		if err != nil {
			t.Fatalf("unauthorized status request failed: %v", err)
		}
		_, _ = io.Copy(io.Discard, badResp.Body)
		_ = badResp.Body.Close()
		if badResp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("unauthorized code=%d, want 401", badResp.StatusCode)
		}

		// 确认显式 InstallOnce 已开启 EmbedMode，独立进程专用 /restart 保持关闭。
		restartReq, err := http.NewRequest(http.MethodPost, "http://"+options.Controller+"/restart", nil)
		if err != nil {
			t.Fatal(err)
		}
		restartReq.Header.Set("Authorization", "Bearer "+secret)
		restartResp, err := client.Do(restartReq)
		if err != nil {
			t.Fatalf("restart probe failed: %v", err)
		}
		_, _ = io.Copy(io.Discard, restartResp.Body)
		_ = restartResp.Body.Close()
		if restartResp.StatusCode == http.StatusOK || restartResp.StatusCode == http.StatusNoContent {
			t.Fatalf("embed mode did not disable /restart: status=%d", restartResp.StatusCode)
		}
		return got.BootID
	}

	// 覆盖连续两次 Start -> Stop -> Start，验证 InstallOnce 幂等不触发 chi 重复挂载 panic。
	InstallOnce(testEng)
	if err := testEng.Start(options); err != nil {
		t.Fatal(err)
	}
	defer testEng.Stop()
	firstBoot := checkRunning(options.Secret)

	if err := testEng.Stop(); err != nil {
		t.Fatal(err)
	}

	InstallOnce(testEng)
	options.Secret = "arkclash-status-secret-second"
	if err := testEng.Start(options); err != nil {
		t.Fatal(err)
	}
	secondBoot := checkRunning(options.Secret)
	if secondBoot == firstBoot {
		t.Fatalf("second boot reused first bootId %q", firstBoot)
	}
}
