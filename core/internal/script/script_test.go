package script

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestEvaluateFlClashContract(t *testing.T) {
	input := []byte(`{"rules":["MATCH,DIRECT"],"proxy-providers":{},"proxies":[{"name":"香港"}]}`)
	for _, source := range []string{
		`function main(config) { return config }`,
		`const main = config => ({ ...config, rules: [...new Set(config.rules)] })`,
		`async function main(config) { return await Promise.resolve(config) }`,
		`let main = async config => await Promise.resolve().then(() => config)`,
		`const main = config => { config.rules = []; return null }`,
		`function main(config) { config.rules.length = 0 }`,
		`const main = c => { console.log(c); console.trace(c); return c }`,
		`const main = c => { if (typeof fetch !== 'undefined' || typeof require !== 'undefined' || typeof setTimeout !== 'undefined') throw 1; return c }`,
	} {
		out, err := Evaluate(t.Context(), source, input)
		if err != nil {
			t.Fatalf("%s: %v", source, err)
		}
		var decoded struct{ Rules []string }
		if err := json.Unmarshal(out, &decoded); err != nil || len(decoded.Rules) != 1 || decoded.Rules[0] != "MATCH,DIRECT" {
			t.Fatalf("%s: rules changed: %s (%v)", source, out, err)
		}
	}
}

func TestEvaluateFailures(t *testing.T) {
	for _, tc := range []struct{ source, code string }{
		{"// 中文\nfunction main( {", "syntax"},
		{`const something = 1`, "entry"},
		{`function main(config) { throw new Error(config.token) }`, "execution"},
		{`async function main(config) { throw new Error(config.token) }`, "rejection"},
		{`const main = () => new Promise(() => {})`, "pending"},
		{`const main = () => []`, "return"},
		{`const main = () => 'scalar'`, "return"},
		{`const main = () => ({toJSON() { return [] }})`, "return"},
		{`const main = c => { c.self = c; return c }`, "return"},
		{`const main = () => { function recursive() { return { value: recursive() } } return recursive() }`, "stack"},
		{`const main = () => ({large: new ArrayBuffer(270 * 1024 * 1024)})`, "memory"},
		{`const main = () => ({large: 'x'.repeat(65 * 1024 * 1024)})`, "size"},
		{`const main = () => { while (true) {} }`, "timeout"},
		{`const main = async () => { while (true) await 0 }`, "timeout"},
	} {
		t.Run(tc.code, func(t *testing.T) {
			timeout := Timeout
			if tc.code == "timeout" {
				timeout = 250 * time.Millisecond
			}
			_, err := evaluate(t.Context(), tc.source, []byte(`{"token":"private-value"}`), timeout)
			var failure *Error
			if !errors.As(err, &failure) || failure.Code != tc.code || strings.Contains(err.Error(), "private-value") {
				t.Fatalf("wanted %s, got %v", tc.code, err)
			}
			if tc.code == "syntax" && failure.Line != 2 {
				t.Fatalf("expected line 2: %v", failure)
			}
		})
	}
}

func TestCanceledAndRepeatedEvaluations(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	timer := time.AfterFunc(30*time.Millisecond, cancel)
	defer timer.Stop()
	defer cancel()
	_, err := Evaluate(ctx, `const main = () => { for (;;) {} }`, []byte(`{}`))
	var failure *Error
	if !errors.As(err, &failure) || failure.Code != "canceled" {
		t.Fatalf("expected cancellation, got %v", err)
	}
	started := time.Now()
	for range 100 {
		if _, err := Evaluate(t.Context(), `const main = async c => await c`, []byte(`{}`)); err != nil {
			t.Fatal(err)
		}
	}
	t.Logf("100 次独立 QuickJS 执行耗时 %s", time.Since(started))
}
