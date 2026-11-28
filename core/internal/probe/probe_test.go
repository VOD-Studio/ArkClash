package probe

import (
	"regexp"
	"strings"
	"testing"
)

func TestProbeBodyModesAndScanWindow(t *testing.T) {
	if got, err := ReadBody(strings.NewReader("ignored"), "none", nil); err != nil || got != "" {
		t.Fatalf("none mode: got=%q err=%v", got, err)
	}
	if _, err := ReadBody(strings.NewReader(strings.Repeat("x", JSONLimit+1)), "json", nil); err == nil || err.Error() != "probe_json_too_large" {
		t.Fatalf("oversize json err=%v", err)
	}
	// 跨 32 KiB 窗口边界的扫描目标也必须被 overlap 窗口捕获。
	prefix := strings.Repeat("a", ScanChunk-3)
	payload := prefix + "MARKER-DENIED"
	got, err := ReadBody(strings.NewReader(payload), "scan", regexp.MustCompile(`MARKER`))
	if err != nil || got != "MARKER-DENIED" {
		t.Fatalf("boundary scan got=%q err=%v", got, err)
	}
}
