package config

import (
	"errors"
	"os"
	"slices"
	"strings"

	"github.com/VOD-Studio/ArkClash/core/internal/backup"
	"github.com/VOD-Studio/ArkClash/core/internal/ruleset"
	mihomoConfig "github.com/metacubex/mihomo/config"
	mihomoRules "github.com/metacubex/mihomo/rules"
	"github.com/metacubex/mihomo/rules/common"
)

type AddedRule struct {
	ID         string `json:"id"`
	Kind       string `json:"kind"`
	Payload    string `json:"payload"`
	Target     string `json:"target"`
	CustomExit bool   `json:"customExit,omitempty"`
	NoResolve  bool   `json:"noResolve"`
	Source     bool   `json:"source"`
}

type AddedRulesSettings struct {
	Revision string              `json:"revision"`
	Rules    []AddedRule         `json:"rules"`
	Profiles []ProfileAddedRules `json:"profiles,omitempty"`
}

type ProfileAddedRules struct {
	Profile     string          `json:"profile"`
	Revision    string          `json:"revision"`
	Rules       []AddedRule     `json:"rules"`
	Disabled    []string        `json:"disabled"`
	MatchTarget string          `json:"matchTarget"`
	ExitTargets []AddedRuleExit `json:"exitTargets,omitempty"`
}

type AddedRuleExit struct {
	Name   string `json:"name"`
	Target string `json:"target"`
}

var ErrAddedRulesMatchTarget = errors.New("added_rules_match_target")

func (r AddedRule) Valid() bool {
	if r.ID == "" || len(r.ID) > 80 || r.Payload == "" || len(r.Payload) > 2048 ||
		strings.TrimSpace(r.Payload) != r.Payload || strings.ContainsAny(r.Payload, "\x00\r\n") {
		return false
	}
	if r.CustomExit {
		if !ValidExitName(r.Target) {
			return false
		}
	} else if r.Target != "MATCH" && !BuiltinRuleTarget(r.Target) {
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

func (s AddedRulesSettings) Validate() error {
	if s.Revision == "" || len(s.Revision) > 80 || !validAddedRuleList(s.Rules) {
		return ErrSettingsInvalid
	}
	profiles := make(map[string]bool)
	for _, profile := range s.Profiles {
		id := profile.Profile
		if !ValidProfileID(id) || profiles[id] ||
			profile.Revision == "" || len(profile.Revision) > 80 || !validAddedRuleList(profile.Rules) ||
			profile.Disabled == nil || len(profile.Disabled) > 1000 || len(profile.MatchTarget) > 1024 ||
			(profile.MatchTarget != "" && !ValidRuleTargetName(profile.MatchTarget)) || len(profile.ExitTargets) > 1000 {
			return ErrSettingsInvalid
		}
		exits := make(map[string]bool, len(profile.ExitTargets))
		for _, exit := range profile.ExitTargets {
			if !ValidExitName(exit.Name) || !ValidRuleTargetName(exit.Target) || exits[exit.Name] {
				return ErrSettingsInvalid
			}
			exits[exit.Name] = true
		}
		disabled := make(map[string]bool, len(profile.Disabled))
		for _, ruleID := range profile.Disabled {
			if ruleID == "" || len(ruleID) > 80 || disabled[ruleID] {
				return ErrSettingsInvalid
			}
			disabled[ruleID] = true
		}
		profiles[id] = true
	}
	return nil
}

func validAddedRuleList(rules []AddedRule) bool {
	if rules == nil || len(rules) > 1000 {
		return false
	}
	ids := make(map[string]bool, len(rules))
	for _, rule := range rules {
		if !rule.Valid() || ids[rule.ID] {
			return false
		}
		ids[rule.ID] = true
	}
	return true
}

func (s AddedRulesSettings) ForProfile(profile string) ProfileAddedRules {
	for _, entry := range s.Profiles {
		if entry.Profile == profile {
			return entry
		}
	}
	return ProfileAddedRules{}
}

func (s AddedRulesSettings) Effective(profile ProfileAddedRules) []AddedRule {
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

func PrependAddedRules(raw *mihomoConfig.RawConfig, added []AddedRule, match string, exits []AddedRuleExit) error {
	if len(added) == 0 {
		return nil
	}
	needsOutbound := slices.ContainsFunc(added, func(rule AddedRule) bool { return rule.CustomExit || rule.Target == "MATCH" })
	if !needsOutbound {
		rules := make([]string, 0, len(added)+len(raw.Rule))
		for _, rule := range added {
			rules = append(rules, rule.Raw(rule.Target))
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
	usable := func(name string) bool { return BuiltinRuleTarget(name) || outbounds[name] }
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
				return ErrAddedRulesMatchTarget
			}
			target = match
		}
		rules = append(rules, rule.Raw(target))
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

func BuiltinRuleTarget(name string) bool {
	switch name {
	case "DIRECT", "REJECT", "REJECT-DROP", "PASS", "PASS-RULE", "COMPATIBLE", "GLOBAL":
		return true
	default:
		return false
	}
}

func ValidRuleTargetName(name string) bool {
	return name != "" && len(name) <= 1024 && strings.TrimSpace(name) == name && !strings.ContainsAny(name, ",\x00\r\n")
}

func ValidExitName(name string) bool {
	return ValidRuleTargetName(name) && !BuiltinRuleTarget(strings.ToUpper(name)) && !strings.EqualFold(name, "MATCH")
}

func (r AddedRule) Raw(target string) string {
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

func AddedRulesPath(home string) string {
	return backup.DataPath(home, "added-rules.json")
}

func ReadAddedRules(home string) (AddedRulesSettings, error) {
	file, err := os.Open(AddedRulesPath(home))
	if errors.Is(err, os.ErrNotExist) {
		return AddedRulesSettings{Revision: "default", Rules: []AddedRule{}}, nil
	}
	if err != nil {
		return AddedRulesSettings{}, ErrSettingsIO
	}
	defer file.Close()
	var settings AddedRulesSettings
	if err := DecodeSettings(file, &settings); err != nil {
		return settings, err
	}
	return settings, settings.Validate()
}

func ValidateAddedRuleContent(rules, previous []AddedRule, catalog RuleSetCatalog) error {
	old := make(map[string]AddedRule, len(previous))
	for _, rule := range previous {
		old[rule.ID] = rule
	}
	for _, rule := range rules {
		if old[rule.ID] == rule {
			continue
		}
		if rule.Kind == "RULE-SET" && catalog.Find(rule.Payload) < 0 {
			return ErrRuleSetInUse
		}
		kind, payload, target, params := common.ParseRulePayload(rule.Raw("DIRECT"), true)
		if _, err := mihomoRules.ParseRule(kind, payload, target, params, nil); err != nil {
			return ErrSettingsInvalid
		}
	}
	return nil
}
