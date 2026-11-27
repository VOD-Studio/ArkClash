package ruleset

import (
	"bytes"
	"testing"

	P "github.com/metacubex/mihomo/constant/provider"
	RP "github.com/metacubex/mihomo/rules/provider"
)

func TestRuleSetFormats(t *testing.T) {
	for _, fixture := range []struct {
		behavior, format, source, compiled string
	}{
		{"domain", "yaml", "payload: [+.example.test, other.test]\n", "+.example.test\nother.test\n"},
		{"ipcidr", "text", "# test\n192.0.2.1/24\n", "192.0.2.0/24\n"},
		{"classical", "yaml", "rules:\n  - DOMAIN-SUFFIX,example.test\n", "DOMAIN-SUFFIX,example.test\n"},
	} {
		got, _, err := Compile([]byte(fixture.source), fixture.behavior, fixture.format)
		if err != nil || string(got) != fixture.compiled {
			t.Fatalf("%s %s: %q, %v", fixture.behavior, fixture.format, got, err)
		}
	}
	for _, fixture := range []struct {
		kind       P.RuleBehavior
		name, text string
	}{
		{P.Domain, "domain", "+.example.test\nfoo.test\n"},
		{P.IPCIDR, "ipcidr", "192.0.2.0/24\n2001:db8::/32\n"},
	} {
		var binary bytes.Buffer
		if err := RP.ConvertToMrs([]byte(fixture.text), fixture.kind, P.TextRule, &binary); err != nil {
			t.Fatal(err)
		}
		if DetectFormat(binary.Bytes()) != "mrs" {
			t.Fatal("MRS was not detected")
		}
		got, count, err := Compile(binary.Bytes(), fixture.name, "mrs")
		if err != nil || count != 2 || !bytes.Contains(got, []byte(fixture.text[:12])) {
			t.Fatalf("MRS %s: %q, %d, %v", fixture.name, got, count, err)
		}
		if _, _, err := Compile(binary.Bytes()[:binary.Len()-1], fixture.name, "mrs"); err == nil {
			t.Fatal("truncated MRS accepted")
		}
	}
	if _, _, err := Compile([]byte("RULE-SET,recursive\n"), "classical", "text"); err == nil {
		t.Fatal("classical set accepted a rule that depends on another provider")
	}
}

func TestRuleSetIdentifiersAndPortableChildGuard(t *testing.T) {
	if !ValidID("cn-direct-1") || ValidID("") || ValidID("../escape") || ValidID("Upper") {
		t.Fatal("ValidID check failed")
	}
	name := ManagedName("demo")
	if !IsManagedName(name) || IsManagedName("user-ruleset") {
		t.Fatalf("unexpected managed name behavior: %q", name)
	}
	if !HasNonPortableChild("((PROCESS-NAME,curl),(DOMAIN,example.test))") ||
		!HasNonPortableChild("((RULE-SET,foo))") ||
		HasNonPortableChild("((DOMAIN,example.test),(DST-PORT,443))") {
		t.Fatal("HasNonPortableChild guard failed")
	}
}
