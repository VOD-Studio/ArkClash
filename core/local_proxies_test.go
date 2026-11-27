package main

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"

	corecfg "github.com/VOD-Studio/ArkClash/core/internal/config"
	"github.com/metacubex/chi"
	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
)

func TestLocalProxyController(t *testing.T) {
	r := chi.NewRouter()
	r.Post("/arkclash/local-proxies/{operation}", postLocalProxies)

	request := func(action string, body string, output any) int {
		t.Helper()
		recorder := httptest.NewRecorder()
		r.ServeHTTP(recorder, httptest.NewRequest(http.MethodPost, "/arkclash/local-proxies/"+action, strings.NewReader(body)))
		if output != nil {
			if err := json.Unmarshal(recorder.Body.Bytes(), output); err != nil {
				t.Fatalf("控制器响应不是预期的 JSON：%v", err)
			}
		}
		return recorder.Code
	}

	const definition = `{"name":"本地演示","type":"ss","server":"192.0.2.50","port":443,"cipher":"aes-128-gcm","password":"synthetic@password/+"}`
	var links []string
	if status := request("encode", `{"definitions":[`+definition+`,{"name":"直接连接","type":"direct"}]}`, &links); status != 200 ||
		len(links) != 2 || !strings.HasPrefix(links[0], "ss://") || links[1] != "" {
		t.Fatalf("分享链接编码失败，HTTP %d", status)
	}

	plainList := links[0] + "\n" + "socks5://192.0.2.51:1080#example"
	body, _ := json.Marshal(corecfg.LocalProxyBody{Lines: []string{links[0], "vless://invalid", base64.StdEncoding.EncodeToString([]byte(plainList))}})
	var decoded [][]map[string]any
	if status := request("decode", string(body), &decoded); status != 200 || len(decoded) != 3 ||
		len(decoded[0]) != 1 || len(decoded[1]) != 0 || len(decoded[2]) != 2 {
		t.Fatalf("分享链接逐行解码失败，HTTP %d", status)
	}
	if decoded[0][0]["name"] != "本地演示" || decoded[0][0]["password"] != "synthetic@password/+" {
		t.Fatal("分享链接往返改变名称或凭据")
	}

	var verdicts []string
	if status := request("validate", `{"definitions":[`+definition+`,{"name":"unknown","type":"missing"}]}`, &verdicts); status != 200 ||
		len(verdicts) != 2 || verdicts[0] != "" || verdicts[1] != "local_proxy_rejected" {
		t.Fatalf("校验结果错误，HTTP %d", status)
	}

	var failure struct{ Message string }
	if status := request("decode", `{"lines":["`+strings.Repeat("a", corecfg.LocalProxyLimit)+`"]}`, &failure); status != 400 ||
		failure.Message != "local_proxy_input" {
		t.Fatalf("超大请求限制失效，HTTP %d", status)
	}
}
