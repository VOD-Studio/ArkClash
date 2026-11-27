package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/VOD-Studio/ArkClash/core/internal/script"
	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/component/age"
	"github.com/metacubex/mihomo/config"
	"go.yaml.in/yaml/v3"
)

const scriptStoreLimit = 16 << 20

var (
	errScriptStore    = errors.New("script_store")
	errScriptMissing  = errors.New("script_missing")
	errScriptConfig   = errors.New("script_config")
	errScriptConflict = errors.New("script_conflict")
	errScriptApply    = errors.New("script_apply")
	scriptSlot        = make(chan struct{}, 1)
)

type scriptRecord struct {
	ID       string `json:"id"`
	Revision string `json:"revision"`
	Source   string `json:"source"`
}

type scriptBinding struct {
	Profile  string `json:"profile"`
	Mode     string `json:"mode"`
	ScriptID string `json:"scriptId"`
}

type scriptStore struct {
	Version  int             `json:"version"`
	Scripts  []scriptRecord  `json:"scripts"`
	Bindings []scriptBinding `json:"bindings"`
}

type profileScript struct {
	identity string
	source   string
}

func (s profileScript) enabled() bool { return s.identity != "" }

func loadProfileExtension(opts *startOptions) error {
	opts.CustomRules, opts.ProfileRules, opts.Script = false, profileAddedRules{}, profileScript{}
	if opts.Profile == "" {
		return nil
	}
	types, err := readProfileTypes(opts.HomeDir)
	if err != nil {
		return err
	}
	opts.CustomRules = types[opts.Profile] == "custom"
	if opts.CustomRules {
		return nil
	}
	opts.ProfileRules = opts.AddedRules.forProfile(opts.Profile)
	opts.Script, err = readProfileScript(opts.HomeDir, opts.Profile)
	return err
}

func readProfileScript(home, profile string) (profileScript, error) {
	if profile == "" {
		return profileScript{}, nil
	}
	file, err := os.Open(filepath.Join(home, "profiles", "scripts.json"))
	if errors.Is(err, os.ErrNotExist) {
		return profileScript{}, nil
	}
	if err != nil {
		return profileScript{}, errScriptStore
	}
	defer file.Close()
	var store scriptStore
	data, err := io.ReadAll(io.LimitReader(file, scriptStoreLimit+1))
	if err != nil || len(data) > scriptStoreLimit || json.Unmarshal(data, &store) != nil || store.Version != 1 ||
		store.Scripts == nil || store.Bindings == nil {
		return profileScript{}, errScriptStore
	}
	for _, binding := range store.Bindings {
		if binding.Profile != profile || binding.Mode == "standard" {
			continue
		}
		if binding.Mode != "script" {
			return profileScript{}, errScriptStore
		}
		if binding.ScriptID == "" {
			return profileScript{identity: "script"}, nil
		}
		for _, record := range store.Scripts {
			if record.ID == binding.ScriptID && record.Revision != "" {
				return profileScript{identity: "script:" + record.ID + ":" + record.Revision, source: record.Source}, nil
			}
		}
		return profileScript{}, errScriptMissing
	}
	return profileScript{}, nil
}

func scriptRawConfig(ctx context.Context, buf []byte, selection profileScript) (*config.RawConfig, error) {
	raw, err := decodeScriptYAML(buf)
	if err != nil {
		return nil, errScriptConfig
	}
	if selection.source == "" {
		return raw, nil
	}
	// RawConfig 的历史 JSON 键是 `rule`，FlClash 传给脚本的是 `rules`。
	if raw.ProxyProvider == nil {
		raw.ProxyProvider = map[string]map[string]any{}
	}
	input, err := json.Marshal(struct {
		*config.RawConfig
		HiddenRule string   `json:"rule,omitempty"`
		Rules      []string `json:"rules"`
	}{RawConfig: raw, Rules: raw.Rule})
	if err != nil {
		return nil, errScriptConfig
	}
	select {
	case scriptSlot <- struct{}{}:
	case <-ctx.Done():
		return nil, &script.Error{Code: "canceled"}
	}
	result, err := script.Evaluate(ctx, selection.source, input)
	<-scriptSlot
	if err != nil {
		return nil, err
	}
	if bytes.Equal(input, result) {
		return raw, nil
	}
	output := config.DefaultRawConfig()
	if err := yaml.Unmarshal(result, output); err != nil {
		return nil, errScriptConfig
	}
	return output, nil
}

func decodeScriptYAML(buf []byte) (*config.RawConfig, error) {
	if !bytes.Contains(buf, []byte("short-id")) {
		return config.UnmarshalRawConfig(buf)
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
	raw := config.DefaultRawConfig()
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

type scriptOutbound struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

type scriptOutbounds struct {
	Groups []scriptOutbound `json:"groups"`
	Nodes  []scriptOutbound `json:"nodes"`
}

func readScriptOutbounds(ctx context.Context, home, profile string) (scriptOutbounds, error) {
	types, err := readProfileTypes(home)
	if err != nil {
		return scriptOutbounds{}, err
	}
	if kind, exists := types[profile]; !exists || kind == "custom" {
		return scriptOutbounds{}, errScriptConflict
	}
	selection, err := readProfileScript(home, profile)
	if err != nil {
		return scriptOutbounds{}, err
	}
	opts := startOptions{HomeDir: home, Profile: profile, Script: selection}
	raw, err := buildRawConfig(ctx, filepath.Join(home, "profiles", profile+".yaml"), opts)
	if err != nil {
		return scriptOutbounds{}, errScriptConfig
	}
	return scriptOutbounds{Groups: collectScriptOutbounds(raw.ProxyGroup), Nodes: collectScriptOutbounds(raw.Proxy)}, nil
}

func collectScriptOutbounds(items []map[string]any) []scriptOutbound {
	outbounds := make([]scriptOutbound, 0, len(items))
	for _, item := range items {
		name, _ := item["name"].(string)
		kind, _ := item["type"].(string)
		if validRuleTargetName(name) && len(kind) <= 80 {
			outbounds = append(outbounds, scriptOutbound{Name: name, Type: kind})
		}
	}
	return outbounds
}

func getScriptOutbounds(w http.ResponseWriter, r *http.Request) {
	profile := r.URL.Query().Get("profile")
	if !addedRulesProfileID.MatchString(profile) || profile == "." || profile == ".." {
		writeError(w, r, http.StatusBadRequest, errScriptConflict)
		return
	}
	view := eng.View()
	if view == nil || !view.Status.Running {
		writeError(w, r, http.StatusServiceUnavailable, errScriptConflict)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	outbounds, err := readScriptOutbounds(ctx, view.HomeDir, profile)
	if err != nil {
		writeError(w, r, http.StatusBadRequest, err)
		return
	}
	render.JSON(w, r, outbounds)
}

type scriptApplyRequest struct {
	BootID           string  `json:"bootId"`
	Profile          string  `json:"profile"`
	Identity         string  `json:"identity"`
	StandardRevision *string `json:"standardRevision,omitempty"`
}

func (request scriptApplyRequest) selectedRules(options startOptions) (profileAddedRules, error) {
	if request.StandardRevision == nil {
		return options.ProfileRules, nil
	}
	rules := options.AddedRules.forProfile(request.Profile)
	if rules.Revision != *request.StandardRevision {
		return profileAddedRules{}, errProfileSettingsConflict
	}
	return rules, nil
}

func postProfileScript(w http.ResponseWriter, r *http.Request) {
	var request scriptApplyRequest
	if err := decodeProfileSettings(r.Body, &request); err != nil || request.Profile == "" || request.BootID == "" {
		writeError(w, r, http.StatusBadRequest, errScriptConflict)
		return
	}
	if err := applyProfileScript(r.Context(), request); err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, errScriptConflict) || errors.Is(err, errProfileSettingsConflict) {
			status = http.StatusConflict
		}
		writeError(w, r, status, err)
		return
	}
	render.NoContent(w, r)
}

func applyProfileScript(ctx context.Context, request scriptApplyRequest) error {
	var (
		next     startOptions
		revision uint64
		conflict bool
	)
	_ = eng.withState(func(tx *stateTx) error {
		if !eng.running || eng.bootID != request.BootID || eng.current.Profile != request.Profile || eng.current.CustomRules || eng.cleanupFailure != nil {
			conflict = true
			return nil
		}
		next, revision = eng.current, eng.configRevision
		return nil
	})
	if conflict {
		return errScriptConflict
	}

	selection, err := readProfileScript(next.HomeDir, request.Profile)
	if err != nil {
		return err
	}
	if selection.identity != request.Identity {
		return errScriptConflict
	}
	standard, err := request.selectedRules(next)
	if err != nil {
		return err
	}
	if next.Script.identity == selection.identity && next.ProfileRules.Revision == standard.Revision {
		return nil
	}
	next.Script = selection
	path := next.ConfigPath
	raw, hash, err := buildRawConfigWithHash(ctx, path, next)
	if errors.Is(err, os.ErrNotExist) {
		// 更新成功后，候选文件已原子改名成配置的固定路径。
		path = filepath.Join(next.HomeDir, "profiles", request.Profile+".yaml")
		raw, hash, err = buildRawConfigWithHash(ctx, path, next)
	}
	if err != nil {
		if scriptError := new(script.Error); errors.As(err, &scriptError) {
			return scriptError
		}
		return errScriptConfig
	}

	return eng.withState(func(tx *stateTx) error {
		if ctx.Err() != nil || !eng.running || eng.bootID != request.BootID || revision != eng.configRevision || eng.cleanupFailure != nil {
			return errScriptConflict
		}
		latest, err := readProfileScript(next.HomeDir, request.Profile)
		if err != nil || latest.identity != selection.identity {
			return errScriptConflict
		}
		standard, err = request.selectedRules(eng.current)
		if err != nil {
			return err
		}
		// 模式和局域网开关可以在脚本执行时变化，但不会增加配置版本。
		next = eng.current
		next.ConfigPath, next.Script, next.ContentHash = path, selection, hash
		next.ProfileRules = standard
		var inbounds inboundSettings
		cfg, err := prepareRawConfig(raw, next, &inbounds)
		if err != nil {
			if errors.Is(err, errAddedRulesMatchTarget) || errors.Is(err, errDNSProxyServersRequired) {
				return err
			}
			if !selection.enabled() {
				return errProfileSettingsInvalid
			}
			return errScriptConfig
		}
		if eng.tun != nil && !dnsListenerAvailable(inbounds.dnsListen, inbounds.dnsMark) {
			return errScriptConfig
		}
		if _, err := tx.CommitReload(reloadPlan{Next: next, Cfg: cfg, Inbound: inbounds}); err != nil {
			return errScriptApply
		}
		return nil
	})
}
