package subfetch

import (
	"encoding/base64"
	"io"
	"strings"
	"testing"
)

func TestShareLinkBody(t *testing.T) {
	link := "trojan://secret@192.0.2.51:443?sni=example.com#fixture"
	for _, tt := range []struct {
		input   string
		convert bool
	}{
		{base64.StdEncoding.EncodeToString([]byte(link)), true},
		{link + "\n", true},
		{"proxies:\n  - {name: a, type: ss}\n", false},
		{strings.Repeat("# 注释\n", 2000) + "proxies: []\n", false},
	} {
		reader, err := ShareLinkBody(strings.NewReader(tt.input), 1<<20)
		if err != nil {
			t.Fatal(err)
		}
		out, _ := io.ReadAll(reader)
		if converted := strings.Contains(string(out), "MATCH,PROXY"); converted != tt.convert {
			t.Fatalf("%.40q 转换 = %v，期望 %v", tt.input, converted, tt.convert)
		}
		if !tt.convert && string(out) != tt.input {
			t.Fatal("非分享链接内容被改动")
		}
	}
	if _, err := ShareLinkBody(strings.NewReader(link+"\n"+strings.Repeat("A", 64)), 16); err == nil {
		t.Fatal("超过上限未报错")
	}
}
