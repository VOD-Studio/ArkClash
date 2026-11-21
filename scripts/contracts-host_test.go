package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"testing"
	"testing/iotest"

	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
	"github.com/metacubex/mihomo/constant"
)

type configContractFixture struct {
	YAML       string
	BaseGroup  string
	Script     string
	AddedRules addedRulesSettings
	Standard   []string
	Scripted   []string
	Custom     []string
}

type contractFixtures struct {
	DefaultSettings        json.RawMessage
	SettingsRequest        json.RawMessage
	InvalidSettingsRequest json.RawMessage
	SettingsError          json.RawMessage
	Configuration          configContractFixture
}

func readContractFixtures(t *testing.T) contractFixtures {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("internal", "testdata", "contracts.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixtures contractFixtures
	if err := json.Unmarshal(data, &fixtures); err != nil {
		t.Fatal(err)
	}
	return fixtures
}

func requireContractJSON(t *testing.T, actual, expected []byte) {
	t.Helper()
	var got, want any
	if err := json.Unmarshal(actual, &got); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(expected, &want); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("契约 JSON 不一致\n实际：%s\n预期：%s", actual, expected)
	}
}

func TestProfileSettingsContract(t *testing.T) {
	cases := readContractFixtures(t)
	opts := lifecycleOptions(t)
	defaults, err := readGeneralSettings(opts.HomeDir)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(defaults)
	if err != nil {
		t.Fatal(err)
	}
	requireContractJSON(t, encoded, cases.DefaultSettings)

	var request profileSettingsRequest[generalSettings]
	reader := iotest.OneByteReader(bytes.NewReader(cases.SettingsRequest))
	if err := decodeProfileSettings(reader, &request); err != nil {
		t.Fatal(err)
	}
	encoded, err = json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	requireContractJSON(t, encoded, cases.SettingsRequest)

	if err := start(opts); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = stop() })
	bad := httptest.NewRecorder()
	postGeneralSettings(bad, httptest.NewRequest(http.MethodPost, "/arkclash/general/settings",
		bytes.NewReader(cases.InvalidSettingsRequest)))
	if bad.Code != http.StatusBadRequest {
		t.Fatalf("错误字段应返回 400，得到 %d", bad.Code)
	}
	requireContractJSON(t, bad.Body.Bytes(), cases.SettingsError)

	request.BootID = runtimeSnapshot.Load().BootID
	encoded, err = json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	ok := httptest.NewRecorder()
	postGeneralSettings(ok, httptest.NewRequest(http.MethodPost, "/arkclash/general/settings", bytes.NewReader(encoded)))
	if ok.Code != http.StatusNoContent || ok.Body.Len() != 0 {
		t.Fatalf("保存应返回空的 204，得到 %d %s", ok.Code, ok.Body.String())
	}
	saved, err := readGeneralSettings(opts.HomeDir)
	if err != nil || !reflect.DeepEqual(saved, request.Settings) {
		t.Fatalf("保存没有完整保留字段：%+v，%v", saved, err)
	}
}

func TestConfigTransformationContract(t *testing.T) {
	fixture := readContractFixtures(t).Configuration
	opts := lifecycleOptions(t)
	opts.Profile = "fixture"
	opts.AddedRules = fixture.AddedRules
	opts.ProfileRules = opts.AddedRules.forProfile(opts.Profile)
	path := lifecycleWriteProfile(t, opts, opts.Profile, fixture.YAML)
	for _, tc := range []struct {
		name     string
		script   profileScript
		isCustom bool
		rules    []string
	}{
		{name: "standard", rules: fixture.Standard},
		{name: "script", script: profileScript{identity: "fixture", source: fixture.Script}, rules: fixture.Scripted},
		{name: "custom", isCustom: true, rules: fixture.Custom},
	} {
		t.Run(tc.name, func(t *testing.T) {
			options := opts
			options.Script = tc.script
			options.CustomRules = tc.isCustom
			cfg, err := parseConfig(path, options)
			if err != nil {
				t.Fatal(err)
			}
			if cfg.Proxies[fixture.BaseGroup] == nil {
				t.Fatal("配置变换丢失了原配置的代理组")
			}
			got := make([]string, 0, len(cfg.Rules))
			for _, rule := range cfg.Rules {
				payload := rule.Payload()
				if rule.RuleType() == constant.MATCH {
					payload = ""
				}
				got = append(got, payload+","+rule.Adapter())
			}
			if !slices.Equal(got, tc.rules) {
				t.Fatalf("规则顺序或目标不一致\n实际：%v\n预期：%v", got, tc.rules)
			}
		})
	}
}
