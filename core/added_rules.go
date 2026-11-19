package main

import (
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/config"
	mihomoRules "github.com/metacubex/mihomo/rules"
	"github.com/metacubex/mihomo/rules/common"
)

type addedRule struct {
	ID        string `json:"id"`
	Kind      string `json:"kind"`
	Payload   string `json:"payload"`
	Target    string `json:"target"`
	NoResolve bool   `json:"noResolve"`
	Source    bool   `json:"source"`
}

type addedRulesSettings struct {
	Revision string      `json:"revision"`
	Rules    []addedRule `json:"rules"`
}

var nonPortableChild = regexp.MustCompile(`(?i)\(\s*(RULE-SET|SUB-RULE|UID|PROCESS-[A-Z-]+)\s*,`)

func (r addedRule) valid() bool {
	if r.ID == "" || len(r.ID) > 80 || r.Payload == "" || len(r.Payload) > 2048 ||
		strings.TrimSpace(r.Payload) != r.Payload || strings.ContainsAny(r.Payload, "\x00\r\n") {
		return false
	}
	switch r.Target {
	case "DIRECT", "REJECT", "REJECT-DROP", "PASS", "PASS-RULE", "COMPATIBLE", "GLOBAL", "MATCH":
	default:
		return false
	}
	switch r.Kind {
	case "IP-CIDR", "IP-CIDR6", "IP-SUFFIX", "IP-ASN", "GEOIP":
		return !strings.Contains(r.Payload, ",")
	case "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-WILDCARD", "GEOSITE", "SRC-GEOIP",
		"SRC-IP-ASN", "SRC-IP-CIDR", "SRC-IP-SUFFIX", "DST-PORT", "SRC-PORT", "IN-PORT", "IN-TYPE",
		"IN-USER", "IN-NAME", "REMATCH-NAME", "NETWORK", "DSCP":
		return !r.NoResolve && !r.Source && !strings.Contains(r.Payload, ",")
	case "AND", "OR", "NOT":
		return !r.NoResolve && !r.Source && !nonPortableChild.MatchString(r.Payload)
	case "DOMAIN-REGEX":
		return !r.NoResolve && !r.Source
	default:
		return false
	}
}

func (s addedRulesSettings) validate() error {
	if s.Revision == "" || len(s.Revision) > 80 || s.Rules == nil || len(s.Rules) > 1000 {
		return errProfileSettingsInvalid
	}
	ids := make(map[string]bool, len(s.Rules))
	for _, rule := range s.Rules {
		if !rule.valid() || ids[rule.ID] {
			return errProfileSettingsInvalid
		}
		ids[rule.ID] = true
	}
	return nil
}

func (s addedRulesSettings) apply(raw *config.RawConfig) {
	if len(s.Rules) == 0 {
		return
	}
	match := "DIRECT"
	for i := len(raw.Rule) - 1; i >= 0; i-- {
		kind, _, target, _ := common.ParseRulePayload(raw.Rule[i], true)
		if kind == "MATCH" && target != "" {
			match = target
			break
		}
	}
	rules := make([]string, 0, len(s.Rules)+len(raw.Rule))
	for _, rule := range s.Rules {
		rules = append(rules, rule.raw(match))
	}
	raw.Rule = append(rules, raw.Rule...)
}

func (r addedRule) raw(match string) string {
	target := r.Target
	if target == "MATCH" {
		target = match
	}
	text := r.Kind + "," + r.Payload + "," + target
	if r.NoResolve {
		text += ",no-resolve"
	}
	if r.Source {
		text += ",src"
	}
	return text
}

func addedRulesPath(home string) string {
	return filepath.Join(home, "added-rules.json")
}

func readAddedRules(home string) (addedRulesSettings, error) {
	file, err := os.Open(addedRulesPath(home))
	if errors.Is(err, os.ErrNotExist) {
		return addedRulesSettings{Revision: "default", Rules: []addedRule{}}, nil
	}
	if err != nil {
		return addedRulesSettings{}, errProfileSettingsIO
	}
	defer file.Close()
	var settings addedRulesSettings
	if err := decodeProfileSettings(file, &settings); err != nil {
		return settings, err
	}
	return settings, settings.validate()
}

func postAddedRules(w http.ResponseWriter, r *http.Request) {
	var request profileSettingsRequest[addedRulesSettings]
	if err := decodeProfileSettings(r.Body, &request); err != nil {
		writeError(w, r, http.StatusBadRequest, err)
		return
	}
	if err := updateAddedRules(request); err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, errProfileSettingsConflict) {
			status = http.StatusConflict
		}
		writeError(w, r, status, err)
		return
	}
	render.NoContent(w, r)
}

func updateAddedRules(request profileSettingsRequest[addedRulesSettings]) error {
	mu.Lock()
	var wait func()
	defer func() {
		mu.Unlock()
		if wait != nil {
			wait()
		}
	}()
	if !profileSettingsCurrent(request.BootID, request.ExpectedRevision, current.AddedRules.Revision, request.Settings.Revision) {
		return errProfileSettingsConflict
	}
	if err := request.Settings.validate(); err != nil {
		return err
	}
	next := current
	next.AddedRules = request.Settings
	if next.Profile == "" {
		for _, rule := range next.AddedRules.Rules {
			kind, payload, target, params := common.ParseRulePayload(rule.raw("DIRECT"), true)
			if _, err := mihomoRules.ParseRule(kind, payload, target, params, nil); err != nil {
				return errProfileSettingsInvalid
			}
		}
	}
	var err error
	wait, err = applyProfileSettingsLocked(next, addedRulesPath(next.HomeDir), next.AddedRules)
	return err
}
