package main

import (
	"errors"
	"os"
	"slices"

	corecfg "github.com/VOD-Studio/ArkClash/core/internal/config"
	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
)

func postAddedRules(w http.ResponseWriter, r *http.Request) {
	var request corecfg.SettingsRequest[corecfg.AddedRulesSettings]
	if err := corecfg.DecodeSettings(r.Body, &request); err != nil {
		writeError(w, r, http.StatusBadRequest, err)
		return
	}
	if err := updateAddedRules(request); err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, corecfg.ErrSettingsConflict) {
			status = http.StatusConflict
		}
		writeError(w, r, status, err)
		return
	}
	render.NoContent(w, r)
}

func updateAddedRules(request corecfg.SettingsRequest[corecfg.AddedRulesSettings]) error {
	return eng.withState(func(tx *stateTx) error {
		if !profileSettingsCurrent(request.BootID, request.ExpectedRevision, eng.current.AddedRules.Revision, request.Settings.Revision) {
			return corecfg.ErrSettingsConflict
		}
		if err := request.Settings.Validate(); err != nil {
			return err
		}
		next := eng.current
		next.AddedRules = request.Settings
		if next.AddedRules.Profiles == nil {
			next.AddedRules.Profiles = slices.Clone(eng.current.AddedRules.Profiles)
		}
		if len(next.AddedRules.Profiles) > 0 {
			types, err := corecfg.ReadProfileTypes(next.HomeDir)
			if err != nil {
				return err
			}
			if types != nil {
				for _, entry := range next.AddedRules.Profiles {
					kind, exists := types[entry.Profile]
					if (!exists || kind == "custom") &&
						entry.Revision != eng.current.AddedRules.ForProfile(entry.Profile).Revision {
						return corecfg.ErrSettingsConflict
					}
				}
				next.AddedRules.Profiles = slices.DeleteFunc(next.AddedRules.Profiles, func(entry corecfg.ProfileAddedRules) bool {
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
			prior := eng.current.AddedRules.ForProfile(entry.Profile)
			if entry.Revision == prior.Revision &&
				(!slices.Equal(entry.Rules, prior.Rules) || entry.MatchTarget != prior.MatchTarget ||
					!slices.Equal(entry.ExitTargets, prior.ExitTargets) ||
					!slices.Equal(entry.Disabled, slices.DeleteFunc(slices.Clone(prior.Disabled), func(id string) bool {
						return !globalIDs[id]
					}))) {
				return corecfg.ErrSettingsConflict
			}
			if err := corecfg.ValidateAddedRuleContent(entry.Rules, prior.Rules, next.RuleSets); err != nil {
				return err
			}
		}
		if err := corecfg.ValidateAddedRuleContent(next.AddedRules.Rules, eng.current.AddedRules.Rules, next.RuleSets); err != nil {
			return err
		}
		next.ProfileRules.Disabled = slices.DeleteFunc(slices.Clone(eng.current.ProfileRules.Disabled), func(id string) bool {
			return !globalIDs[id]
		})
		if next.Profile == "" || next.CustomRules ||
			slices.Equal(eng.current.AddedRules.Effective(eng.current.ProfileRules), next.AddedRules.Effective(next.ProfileRules)) {
			path := corecfg.AddedRulesPath(next.HomeDir)
			staged, err := corecfg.StageSettings(path, next.AddedRules)
			if err != nil {
				return err
			}
			defer os.Remove(staged)
			if err := os.Rename(staged, path); err != nil {
				return corecfg.ErrSettingsIO
			}
			eng.setCurrentLocked(next)
			return nil
		}
		return tx.CommitSettingsFile(next, corecfg.AddedRulesPath(next.HomeDir), next.AddedRules)
	})
}
