package main

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"

	"github.com/VOD-Studio/ArkClash/core/internal/ruleset"
	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/config"
	mihomoRules "github.com/metacubex/mihomo/rules"
	"github.com/metacubex/mihomo/rules/common"
)

type addedRule struct {
	ID         string `json:"id"`
	Kind       string `json:"kind"`
	Payload    string `json:"payload"`
	Target     string `json:"target"`
	CustomExit bool   `json:"customExit,omitempty"`
	NoResolve  bool   `json:"noResolve"`
	Source     bool   `json:"source"`
}

type addedRulesSettings struct {
	Revision string              `json:"revision"`
	Rules    []addedRule         `json:"rules"`
	Profiles []profileAddedRules `json:"profiles,omitempty"`
}

type profileAddedRules struct {
	Profile     string          `json:"profile"`
	Revision    string          `json:"revision"`
	Rules       []addedRule     `json:"rules"`
	Disabled    []string        `json:"disabled"`
	MatchTarget string          `json:"matchTarget"`
	ExitTargets []addedRuleExit `json:"exitTargets,omitempty"`
}

type addedRuleExit struct {
	Name   string `json:"name"`
	Target string `json:"target"`
}

var addedRulesProfileID = regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)
var errAddedRulesMatchTarget = errors.New("added_rules_match_target")

func (r addedRule) valid() bool {
	if r.ID == "" || len(r.ID) > 80 || r.Payload == "" || len(r.Payload) > 2048 ||
		strings.TrimSpace(r.Payload) != r.Payload || strings.ContainsAny(r.Payload, "\x00\r\n") {
		return false
	}
	if r.CustomExit {
		if !validExitName(r.Target) {
			return false
		}
	} else if r.Target != "MATCH" && !builtinRuleTarget(r.Target) {
		return false
	}
	switch r.Kind {
	case "RULE-SET":
		return ruleset.ValidID(r.Payload)
	case "IP-CIDR", "IP-CIDR6", "IP-SUFFIX", "IP-ASN", "GEOIP":
		return !strings.Contains(r.Payload, ",")
	case "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-WILDCARD", "GEOSITE", "SRC-GEOIP",
		"SRC-IP-ASN", "SRC-IP-CIDR", "SRC-IP-SUFFIX", "DST-PORT", "SRC-PORT", "IN-PORT", "IN-TYPE",
		"IN-USER", "IN-NAME", "REMATCH-NAME", "NETWORK", "DSCP":
		return !r.NoResolve && !r.Source && !strings.Contains(r.Payload, ",")
	case "AND", "OR", "NOT":
		return !r.NoResolve && !r.Source && !ruleset.HasNonPortableChild(r.Payload)
	case "DOMAIN-REGEX":
		return !r.NoResolve && !r.Source
	default:
		return false
	}
}

func (s addedRulesSettings) validate() error {
	if s.Revision == "" || len(s.Revision) > 80 || !validAddedRuleList(s.Rules) {
		return errProfileSettingsInvalid
	}
	profiles := make(map[string]bool)
	for _, profile := range s.Profiles {
		id := profile.Profile
		if !addedRulesProfileID.MatchString(id) || id == "." || id == ".." || profiles[id] ||
			profile.Revision == "" || len(profile.Revision) > 80 || !validAddedRuleList(profile.Rules) ||
			profile.Disabled == nil || len(profile.Disabled) > 1000 || len(profile.MatchTarget) > 1024 ||
			(profile.MatchTarget != "" && !validRuleTargetName(profile.MatchTarget)) || len(profile.ExitTargets) > 1000 {
			return errProfileSettingsInvalid
		}
		exits := make(map[string]bool, len(profile.ExitTargets))
		for _, exit := range profile.ExitTargets {
			if !validExitName(exit.Name) || !validRuleTargetName(exit.Target) || exits[exit.Name] {
				return errProfileSettingsInvalid
			}
			exits[exit.Name] = true
		}
		disabled := make(map[string]bool, len(profile.Disabled))
		for _, ruleID := range profile.Disabled {
			if ruleID == "" || len(ruleID) > 80 || disabled[ruleID] {
				return errProfileSettingsInvalid
			}
			disabled[ruleID] = true
		}
		profiles[id] = true
	}
	return nil
}

func validAddedRuleList(rules []addedRule) bool {
	if rules == nil || len(rules) > 1000 {
		return false
	}
	ids := make(map[string]bool, len(rules))
	for _, rule := range rules {
		if !rule.valid() || ids[rule.ID] {
			return false
		}
		ids[rule.ID] = true
	}
	return true
}

func (s addedRulesSettings) forProfile(profile string) profileAddedRules {
	for _, entry := range s.Profiles {
		if entry.Profile == profile {
			return entry
		}
	}
	return profileAddedRules{}
}

func (s addedRulesSettings) effective(profile profileAddedRules) []addedRule {
	if len(profile.Disabled) == 0 && len(profile.Rules) == 0 {
		return s.Rules
	}
	disabled := make(map[string]bool, len(profile.Disabled))
	for _, id := range profile.Disabled {
		disabled[id] = true
	}
	effective := slices.Clone(profile.Rules)
	for _, rule := range s.Rules {
		if !disabled[rule.ID] {
			effective = append(effective, rule)
		}
	}
	return effective
}

func prependAddedRules(raw *config.RawConfig, added []addedRule, match string, exits []addedRuleExit) error {
	if len(added) == 0 {
		return nil
	}
	needsOutbound := slices.ContainsFunc(added, func(rule addedRule) bool { return rule.CustomExit || rule.Target == "MATCH" })
	if !needsOutbound {
		rules := make([]string, 0, len(added)+len(raw.Rule))
		for _, rule := range added {
			rules = append(rules, rule.raw(rule.Target))
		}
		raw.Rule = append(rules, raw.Rule...)
		return nil
	}
	outbounds := make(map[string]bool, len(raw.ProxyGroup)+len(raw.Proxy))
	for _, entries := range [][]map[string]any{raw.ProxyGroup, raw.Proxy} {
		for _, entry := range entries {
			if name, ok := entry["name"].(string); ok {
				outbounds[name] = true
			}
		}
	}
	usable := func(name string) bool { return builtinRuleTarget(name) || outbounds[name] }
	fallback := match
	if !usable(fallback) {
		fallback = lastMatchTarget(raw.Rule)
	}
	if match == "" {
		match = fallback
	}
	mapped := make(map[string]string, len(exits))
	for _, exit := range exits {
		if usable(exit.Target) {
			mapped[exit.Name] = exit.Target
		}
	}
	rules := make([]string, 0, len(added)+len(raw.Rule))
	for _, rule := range added {
		target := rule.Target
		if rule.CustomExit {
			switch {
			case mapped[target] != "":
				target = mapped[target]
			case outbounds[target]:
			case usable(fallback):
				target = fallback
			default:
				target = "DIRECT"
			}
		} else if target == "MATCH" {
			if !usable(match) {
				return errAddedRulesMatchTarget
			}
			target = match
		}
		rules = append(rules, rule.raw(target))
	}
	raw.Rule = append(rules, raw.Rule...)
	return nil
}

func lastMatchTarget(rules []string) string {
	for i := len(rules) - 1; i >= 0; i-- {
		kind, _, target, _ := common.ParseRulePayload(rules[i], true)
		if kind == "MATCH" && target != "" {
			return target
		}
	}
	return ""
}

func builtinRuleTarget(name string) bool {
	switch name {
	case "DIRECT", "REJECT", "REJECT-DROP", "PASS", "PASS-RULE", "COMPATIBLE", "GLOBAL":
		return true
	default:
		return false
	}
}

func validRuleTargetName(name string) bool {
	return name != "" && len(name) <= 1024 && strings.TrimSpace(name) == name && !strings.ContainsAny(name, ",\x00\r\n")
}

func validExitName(name string) bool {
	return validRuleTargetName(name) && !builtinRuleTarget(strings.ToUpper(name)) && !strings.EqualFold(name, "MATCH")
}

func (r addedRule) raw(target string) string {
	payload := r.Payload
	if r.Kind == "RULE-SET" {
		payload = ruleset.ManagedName(payload)
	}
	text := r.Kind + "," + payload + "," + target
	if r.NoResolve {
		text += ",no-resolve"
	}
	if r.Source {
		text += ",src"
	}
	return text
}

func addedRulesPath(home string) string {
	return portableDataPath(home, "added-rules.json")
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

func readProfileTypes(home string) (map[string]string, error) {
	file, err := os.Open(filepath.Join(home, "profiles", "list.json"))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, errProfileSettingsIO
	}
	defer file.Close()
	var list struct {
		Profiles []struct {
			ID   string `json:"id"`
			Type string `json:"type"`
		} `json:"profiles"`
	}
	const limit = 8 << 20
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil || len(data) > limit || json.Unmarshal(data, &list) != nil {
		return nil, errProfileSettingsInvalid
	}
	types := make(map[string]string, len(list.Profiles))
	for _, item := range list.Profiles {
		types[item.ID] = item.Type
	}
	return types, nil
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
	return eng.withState(func(tx *stateTx) error {
		if !profileSettingsCurrent(request.BootID, request.ExpectedRevision, eng.current.AddedRules.Revision, request.Settings.Revision) {
			return errProfileSettingsConflict
		}
		if err := request.Settings.validate(); err != nil {
			return err
		}
		next := eng.current
		next.AddedRules = request.Settings
		if next.AddedRules.Profiles == nil {
			next.AddedRules.Profiles = slices.Clone(eng.current.AddedRules.Profiles)
		}
		if len(next.AddedRules.Profiles) > 0 {
			types, err := readProfileTypes(next.HomeDir)
			if err != nil {
				return err
			}
			if types != nil {
				for _, entry := range next.AddedRules.Profiles {
					kind, exists := types[entry.Profile]
					if (!exists || kind == "custom") &&
						entry.Revision != eng.current.AddedRules.forProfile(entry.Profile).Revision {
						return errProfileSettingsConflict
					}
				}
				next.AddedRules.Profiles = slices.DeleteFunc(next.AddedRules.Profiles, func(entry profileAddedRules) bool {
					kind, exists := types[entry.Profile]
					return !exists || kind == "custom"
				})
			}
		}
		globalIDs := make(map[string]bool, len(next.AddedRules.Rules))
		for _, rule := range next.AddedRules.Rules {
			globalIDs[rule.ID] = true
		}
		for i := range next.AddedRules.Profiles {
			entry := &next.AddedRules.Profiles[i]
			entry.Disabled = slices.DeleteFunc(slices.Clone(entry.Disabled), func(id string) bool { return !globalIDs[id] })
			prior := eng.current.AddedRules.forProfile(entry.Profile)
			if entry.Revision == prior.Revision &&
				(!slices.Equal(entry.Rules, prior.Rules) || entry.MatchTarget != prior.MatchTarget ||
					!slices.Equal(entry.ExitTargets, prior.ExitTargets) ||
					!slices.Equal(entry.Disabled, slices.DeleteFunc(slices.Clone(prior.Disabled), func(id string) bool {
						return !globalIDs[id]
					}))) {
				return errProfileSettingsConflict
			}
			if err := validateAddedRuleContent(entry.Rules, prior.Rules, next.RuleSets); err != nil {
				return err
			}
		}
		if err := validateAddedRuleContent(next.AddedRules.Rules, eng.current.AddedRules.Rules, next.RuleSets); err != nil {
			return err
		}
		next.ProfileRules.Disabled = slices.DeleteFunc(slices.Clone(eng.current.ProfileRules.Disabled), func(id string) bool {
			return !globalIDs[id]
		})
		if next.Profile == "" || next.CustomRules ||
			slices.Equal(eng.current.AddedRules.effective(eng.current.ProfileRules), next.AddedRules.effective(next.ProfileRules)) {
			path := addedRulesPath(next.HomeDir)
			staged, err := stageProfileSettings(path, next.AddedRules)
			if err != nil {
				return err
			}
			defer os.Remove(staged)
			if err := os.Rename(staged, path); err != nil {
				return errProfileSettingsIO
			}
			eng.setCurrentLocked(next)
			return nil
		}
		return tx.CommitSettingsFile(next, addedRulesPath(next.HomeDir), next.AddedRules)
	})
}

func validateAddedRuleContent(rules, previous []addedRule, catalog ruleSetCatalog) error {
	old := make(map[string]addedRule, len(previous))
	for _, rule := range previous {
		old[rule.ID] = rule
	}
	for _, rule := range rules {
		if old[rule.ID] == rule {
			continue
		}
		if rule.Kind == "RULE-SET" && catalog.find(rule.Payload) < 0 {
			return errRuleSetInUse
		}
		kind, payload, target, params := common.ParseRulePayload(rule.raw("DIRECT"), true)
		if _, err := mihomoRules.ParseRule(kind, payload, target, params, nil); err != nil {
			return errProfileSettingsInvalid
		}
	}
	return nil
}
