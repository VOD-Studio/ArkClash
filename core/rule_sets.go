package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"slices"

	corecfg "github.com/VOD-Studio/ArkClash/core/internal/config"
	"github.com/VOD-Studio/ArkClash/core/internal/ruleset"
	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
)

func postRuleSet(w http.ResponseWriter, r *http.Request) {
	var request corecfg.RuleSetRequest
	if err := corecfg.DecodeSettings(r.Body, &request); err != nil {
		writeError(w, r, http.StatusBadRequest, corecfg.ErrRuleSetInput)
		return
	}
	select {
	case eng.ruleSetMutation <- struct{}{}:
		defer func() { <-eng.ruleSetMutation }()
	default:
		writeError(w, r, http.StatusConflict, corecfg.ErrSettingsConflict)
		return
	}
	if err := changeRuleSet(r.Context(), request); err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, corecfg.ErrSettingsConflict) || errors.Is(err, corecfg.ErrRuleSetInUse) {
			status = http.StatusConflict
		}
		writeError(w, r, status, err)
		return
	}
	render.NoContent(w, r)
}

func changeRuleSet(ctx context.Context, request corecfg.RuleSetRequest) error {
	spec, ready := eng.ConfigSpec()
	home, catalog, generation := spec.Options.HomeDir, spec.Options.RuleSets, spec.Options.StoreGeneration
	ok := ready && request.BootID != "" && request.BootID == spec.BootID &&
		request.ExpectedRevision == catalog.Revision && request.Revision != request.ExpectedRevision
	if !ok {
		return corecfg.ErrSettingsConflict
	}
	if !ruleset.ValidID(request.Revision) {
		return corecfg.ErrRuleSetInput
	}
	index := catalog.Find(request.Item.ID)
	var previous corecfg.RuleSetItem
	if index >= 0 {
		previous = catalog.Items[index]
	}
	next := corecfg.RuleSetCatalog{Revision: request.Revision, Items: slices.Clone(catalog.Items)}
	contentChanged, committed := false, false
	switch request.Action {
	case "reorder":
		if len(request.Order) != len(catalog.Items) {
			return corecfg.ErrRuleSetInput
		}
		for n, id := range request.Order {
			i := catalog.Find(id)
			if i < 0 {
				return corecfg.ErrRuleSetInput
			}
			next.Items[n] = catalog.Items[i]
		}
	case "delete":
		if index < 0 {
			return corecfg.ErrSettingsConflict
		}
		next.Items = slices.Delete(next.Items, index, index+1)
	case "save", "sync":
		item := request.Item
		if request.Action == "sync" {
			item = previous
			if item.URL == "" {
				return corecfg.ErrRuleSetInput
			}
		}
		options := item
		if options.Format == "auto" {
			options.Format = "text"
		}
		if options.Behavior == "auto" {
			options.Behavior = "domain"
		}
		if !options.ValidOptions() || (index < 0 && len(catalog.Items) >= 100) {
			return corecfg.ErrRuleSetInput
		}
		for _, other := range catalog.Items {
			if other.ID != item.ID && (other.Name == item.Name || (item.URL != "" && other.URL == item.URL)) {
				return corecfg.ErrRuleSetInput
			}
		}
		item.Content, item.Count, item.UpdatedAt = previous.Content, previous.Count, previous.UpdatedAt
		if request.Action == "sync" || request.Candidate != "" || index < 0 || item.URL != previous.URL ||
			item.Behavior != previous.Behavior || item.Format != previous.Format {
			var err error
			item, contentChanged, err = corecfg.PrepareRuleSet(ctx, home, request, item, previous)
			if err != nil {
				return err
			}
		}
		if contentChanged {
			defer func() {
				if !committed {
					corecfg.RemoveRuleSetFiles(home, item)
				}
			}()
		}
		if index < 0 {
			next.Items = append(next.Items, item)
		} else {
			next.Items[index] = item
		}
	default:
		return corecfg.ErrRuleSetInput
	}
	if err := next.Validate(); err != nil {
		return err
	}
	if encoded, err := json.Marshal(next); err != nil || len(encoded) >= corecfg.ProfileSettingsLimit-1 {
		return corecfg.ErrRuleSetInput
	}
	unlock, err := lockPortableStorage(home)
	if err != nil {
		return corecfg.ErrSettingsConflict
	}
	defer unlock()
	if generation != portableGeneration(home) {
		return corecfg.ErrSettingsConflict
	}
	if err := commitRuleSets(ctx, request, next, contentChanged); err != nil {
		return err
	}
	committed = true
	if previous.Content != "" && (request.Action == "delete" || contentChanged) {
		corecfg.RemoveRuleSetFiles(home, previous)
	}
	return nil
}

func commitRuleSets(ctx context.Context, request corecfg.RuleSetRequest, catalog corecfg.RuleSetCatalog, changed bool) error {
	return eng.withState(func(tx *stateTx) error {
		if ctx.Err() != nil || !profileSettingsCurrent(request.BootID, request.ExpectedRevision, eng.current.RuleSets.Revision, request.Revision) {
			return corecfg.ErrSettingsConflict
		}
		references := func(rule corecfg.AddedRule) bool { return rule.Kind == "RULE-SET" && rule.Payload == request.Item.ID }
		active := eng.current.Profile != "" && !eng.current.CustomRules &&
			slices.ContainsFunc(eng.current.AddedRules.Effective(eng.current.ProfileRules), references)
		if request.Action == "delete" {
			if active || slices.ContainsFunc(eng.current.AddedRules.Rules, references) {
				return corecfg.ErrRuleSetInUse
			}
			if len(eng.current.AddedRules.Profiles) > 0 {
				types, err := corecfg.ReadProfileTypes(eng.current.HomeDir)
				if err != nil {
					return err
				}
				for _, profile := range eng.current.AddedRules.Profiles {
					kind, exists := types[profile.Profile]
					if (types == nil || exists && kind != "custom") && slices.ContainsFunc(profile.Rules, references) {
						return corecfg.ErrRuleSetInUse
					}
				}
			}
		}
		path := corecfg.RuleSetCatalogPath(eng.current.HomeDir)
		if active && changed {
			next := eng.current
			next.RuleSets = catalog
			return tx.CommitSettingsFile(next, path, catalog)
		}
		staged, err := corecfg.StageSettings(path, catalog)
		if err != nil {
			return err
		}
		defer os.Remove(staged)
		if err := os.Rename(staged, path); err != nil {
			return corecfg.ErrSettingsIO
		}
		next := eng.current
		next.RuleSets = catalog
		eng.setCurrentLocked(next)
		return nil
	})
}
