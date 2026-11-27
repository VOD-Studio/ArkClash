package config

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"

	"github.com/VOD-Studio/ArkClash/core/internal/script"
	"github.com/metacubex/mihomo/component/age"
	mihomoConfig "github.com/metacubex/mihomo/config"
	"go.yaml.in/yaml/v3"
)

const ScriptStoreLimit = 16 << 20

var (
	ErrScriptStore    = errors.New("script_store")
	ErrScriptMissing  = errors.New("script_missing")
	ErrScriptConfig   = errors.New("script_config")
	ErrScriptConflict = errors.New("script_conflict")
	ErrScriptApply    = errors.New("script_apply")
	scriptSlot        = make(chan struct{}, 1)
)

type ScriptRecord struct {
	ID       string `json:"id"`
	Revision string `json:"revision"`
	Source   string `json:"source"`
}

type ScriptBinding struct {
	Profile  string `json:"profile"`
	Mode     string `json:"mode"`
	ScriptID string `json:"scriptId"`
}

type ScriptStore struct {
	Version  int             `json:"version"`
	Scripts  []ScriptRecord  `json:"scripts"`
	Bindings []ScriptBinding `json:"bindings"`
}

type ProfileScript struct {
	Identity string
	Source   string
}

func (s ProfileScript) Enabled() bool { return s.Identity != "" }

type ScriptOutbound struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

type ScriptOutbounds struct {
	Groups []ScriptOutbound `json:"groups"`
	Nodes  []ScriptOutbound `json:"nodes"`
}

type ScriptApplyRequest struct {
	BootID           string  `json:"bootId"`
	Profile          string  `json:"profile"`
	Identity         string  `json:"identity"`
	StandardRevision *string `json:"standardRevision,omitempty"`
}

func (request ScriptApplyRequest) SelectedRules(options StartOptions) (ProfileAddedRules, error) {
	if request.StandardRevision == nil {
		return options.ProfileRules, nil
	}
	rules := options.AddedRules.ForProfile(request.Profile)
	if rules.Revision != *request.StandardRevision {
		return ProfileAddedRules{}, ErrSettingsConflict
	}
	return rules, nil
}

func LoadProfileExtension(opts *StartOptions) error {
	opts.CustomRules, opts.ProfileRules, opts.Script = false, ProfileAddedRules{}, ProfileScript{}
	if opts.Profile == "" {
		return nil
	}
	types, err := ReadProfileTypes(opts.HomeDir)
	if err != nil {
		return err
	}
	opts.CustomRules = types[opts.Profile] == "custom"
	if opts.CustomRules {
		return nil
	}
	opts.ProfileRules = opts.AddedRules.ForProfile(opts.Profile)
	opts.Script, err = ReadProfileScript(opts.HomeDir, opts.Profile)
	return err
}

func ReadProfileScript(home, profile string) (ProfileScript, error) {
	if profile == "" {
		return ProfileScript{}, nil
	}
	file, err := os.Open(filepath.Join(home, "profiles", "scripts.json"))
	if errors.Is(err, os.ErrNotExist) {
		return ProfileScript{}, nil
	}
	if err != nil {
		return ProfileScript{}, ErrScriptStore
	}
	defer file.Close()
	var store ScriptStore
	data, err := io.ReadAll(io.LimitReader(file, ScriptStoreLimit+1))
	if err != nil || len(data) > ScriptStoreLimit || json.Unmarshal(data, &store) != nil || store.Version != 1 ||
		store.Scripts == nil || store.Bindings == nil {
		return ProfileScript{}, ErrScriptStore
	}
	for _, binding := range store.Bindings {
		if binding.Profile != profile || binding.Mode == "standard" {
			continue
		}
		if binding.Mode != "script" {
			return ProfileScript{}, ErrScriptStore
		}
		if binding.ScriptID == "" {
			return ProfileScript{Identity: "script"}, nil
		}
		for _, record := range store.Scripts {
			if record.ID == binding.ScriptID && record.Revision != "" {
				return ProfileScript{Identity: "script:" + record.ID + ":" + record.Revision, Source: record.Source}, nil
			}
		}
		return ProfileScript{}, ErrScriptMissing
	}
	return ProfileScript{}, nil
}

func ScriptRawConfig(ctx context.Context, buf []byte, selection ProfileScript) (*mihomoConfig.RawConfig, error) {
	raw, err := decodeScriptYAML(buf)
	if err != nil {
		return nil, ErrScriptConfig
	}
	if selection.Source == "" {
		return raw, nil
	}
	// RawConfig 的历史 JSON 键是 `rule`，FlClash 传给脚本的是 `rules`。
	if raw.ProxyProvider == nil {
		raw.ProxyProvider = map[string]map[string]any{}
	}
	input, err := json.Marshal(struct {
		*mihomoConfig.RawConfig
		HiddenRule string   `json:"rule,omitempty"`
		Rules      []string `json:"rules"`
	}{RawConfig: raw, Rules: raw.Rule})
	if err != nil {
		return nil, ErrScriptConfig
	}
	select {
	case scriptSlot <- struct{}{}:
	case <-ctx.Done():
		return nil, &script.Error{Code: "canceled"}
	}
	result, err := script.Evaluate(ctx, selection.Source, input)
	<-scriptSlot
	if err != nil {
		return nil, err
	}
	if bytes.Equal(input, result) {
		return raw, nil
	}
	output := mihomoConfig.DefaultRawConfig()
	if err := yaml.Unmarshal(result, output); err != nil {
		return nil, ErrScriptConfig
	}
	return output, nil
}

func decodeScriptYAML(buf []byte) (*mihomoConfig.RawConfig, error) {
	if !bytes.Contains(buf, []byte("short-id")) {
		return mihomoConfig.UnmarshalRawConfig(buf)
	}
	plain, err := age.DecryptBytes(buf)
	if err != nil {
		return nil, err
	}
	var document yaml.Node
	if err := yaml.Unmarshal(plain, &document); err != nil {
		return nil, err
	}
	preserveShortIDs(&document)
	raw := mihomoConfig.DefaultRawConfig()
	return raw, document.Decode(raw)
}

func preserveShortIDs(node *yaml.Node) {
	if node.Kind == yaml.MappingNode {
		for index := 0; index+1 < len(node.Content); index += 2 {
			if node.Content[index].Value == "short-id" {
				preserveShortIDScalar(node.Content[index+1])
			}
		}
	}
	for _, child := range node.Content {
		preserveShortIDs(child)
	}
}

func preserveShortIDScalar(node *yaml.Node) {
	switch node.Kind {
	case yaml.ScalarNode:
		if node.Style == 0 && (node.Tag == "!!int" || node.Tag == "!!float") {
			node.Tag = "!!str"
		}
	case yaml.SequenceNode:
		for _, child := range node.Content {
			preserveShortIDScalar(child)
		}
	}
}

func ReadScriptOutbounds(ctx context.Context, home, profile string) (ScriptOutbounds, error) {
	types, err := ReadProfileTypes(home)
	if err != nil {
		return ScriptOutbounds{}, err
	}
	if kind, exists := types[profile]; !exists || kind == "custom" {
		return ScriptOutbounds{}, ErrScriptConflict
	}
	selection, err := ReadProfileScript(home, profile)
	if err != nil {
		return ScriptOutbounds{}, err
	}
	opts := StartOptions{HomeDir: home, Profile: profile, Script: selection}
	raw, err := BuildRawConfig(ctx, filepath.Join(home, "profiles", profile+".yaml"), opts)
	if err != nil {
		return ScriptOutbounds{}, ErrScriptConfig
	}
	return ScriptOutbounds{Groups: collectScriptOutbounds(raw.ProxyGroup), Nodes: collectScriptOutbounds(raw.Proxy)}, nil
}

func collectScriptOutbounds(items []map[string]any) []ScriptOutbound {
	outbounds := make([]ScriptOutbound, 0, len(items))
	for _, item := range items {
		name, _ := item["name"].(string)
		kind, _ := item["type"].(string)
		if ValidRuleTargetName(name) && len(kind) <= 80 {
			outbounds = append(outbounds, ScriptOutbound{Name: name, Type: kind})
		}
	}
	return outbounds
}
