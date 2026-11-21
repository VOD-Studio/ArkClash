package main

import "testing"

func TestProxyFilterUsesMihomoRegexSyntax(t *testing.T) {
	valid := "(?i)🇭🇰|(?<![a-z])hk(?![a-z])" + "`" + "^東京"
	if part := invalidProxyFilterPart(valid); part != 0 {
		t.Fatalf("mihomo expression rejected at part %d", part)
	}
	if part := invalidProxyFilterPart(valid + "`("); part != 3 {
		t.Fatalf("invalid segment index = %d, want 3", part)
	}
}
