package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/VOD-Studio/ArkClash/core/internal/ruleset"
	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/config"
)

var (
	errRuleSetInput    = errors.New("rule_set_input")
	errRuleSetDownload = errors.New("rule_set_download")
	errRuleSetInUse    = errors.New("rule_set_in_use")
	ruleSetMutation    = make(chan struct{}, 1)
)

type ruleSetItem struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	URL       string `json:"url"`
	Behavior  string `json:"behavior"`
	Format    string `json:"format"`
	Content   string `json:"content"`
	Count     int    `json:"count"`
	UpdatedAt int64  `json:"updatedAt"`
}

type ruleSetCatalog struct {
	Revision string        `json:"revision"`
	Items    []ruleSetItem `json:"items"`
}

func (s ruleSetItem) validOptions() bool {
	if !ruleset.ValidID(s.ID) || s.Name == "" || len(s.Name) > 256 ||
		strings.TrimSpace(s.Name) != s.Name || strings.ContainsAny(s.Name, "\x00\r\n") ||
		(s.URL != "" && !validGeoURL(s.URL)) {
		return false
	}
	switch s.Behavior {
	case "domain", "ipcidr", "classical":
	default:
		return false
	}
	return s.Format == "text" || s.Format == "yaml" || (s.Format == "mrs" && s.Behavior != "classical")
}

func (c ruleSetCatalog) validate() error {
	if !ruleset.ValidID(c.Revision) || c.Items == nil || len(c.Items) > 100 {
		return errRuleSetInput
	}
	ids, names, urls := map[string]bool{}, map[string]bool{}, map[string]bool{}
	for _, item := range c.Items {
		if !item.validOptions() || !ruleset.ValidID(item.Content) || item.Count < 1 ||
			item.Count > ruleset.LineLimit || item.UpdatedAt < 1 || ids[item.ID] || names[item.Name] ||
			(item.URL != "" && urls[item.URL]) {
			return errRuleSetInput
		}
		ids[item.ID], names[item.Name], urls[item.URL] = true, true, true
	}
	return nil
}

func (c ruleSetCatalog) find(id string) int {
	return slices.IndexFunc(c.Items, func(item ruleSetItem) bool { return item.ID == id })
}

func ruleSetCatalogPath(home string) string { return portableDataPath(home, "rule-sets.json") }

func (s ruleSetItem) path(home, suffix string) string {
	return filepath.Join(portableDataPath(home, "rule-sets"), s.ID+"."+s.Content+suffix)
}

func readRuleSets(home string) (ruleSetCatalog, error) {
	file, err := os.Open(ruleSetCatalogPath(home))
	if errors.Is(err, os.ErrNotExist) {
		return ruleSetCatalog{Revision: "default", Items: []ruleSetItem{}}, nil
	}
	if err != nil {
		return ruleSetCatalog{}, errProfileSettingsIO
	}
	defer file.Close()
	var catalog ruleSetCatalog
	if err := decodeProfileSettings(file, &catalog); err != nil {
		return catalog, err
	}
	return catalog, catalog.validate()
}

func (c ruleSetCatalog) attach(raw *config.RawConfig, home string, rules []addedRule) error {
	var attached map[string]bool
	for _, item := range rules {
		if item.Kind != "RULE-SET" || attached[item.Payload] {
			continue
		}
		i := c.find(item.Payload)
		if i < 0 {
			return errRuleSetInUse
		}
		entry := c.Items[i]
		path := entry.path(home, ".rules")
		if err := ensureRuleSetCompiled(home, entry, path); err != nil {
			return err
		}
		name := ruleset.ManagedName(entry.ID)
		if raw.RuleProvider == nil {
			raw.RuleProvider = make(map[string]map[string]any)
		}
		if _, exists := raw.RuleProvider[name]; exists {
			return errRuleSetInput
		}
		raw.RuleProvider[name] = map[string]any{"type": "file", "path": path, "format": "text", "behavior": entry.Behavior}
		if attached == nil {
			attached = make(map[string]bool)
		}
		attached[entry.ID] = true
	}
	return nil
}

type ruleSetRequest struct {
	BootID           string      `json:"bootId"`
	ExpectedRevision string      `json:"expectedRevision"`
	Revision         string      `json:"revision"`
	Action           string      `json:"action"`
	Item             ruleSetItem `json:"item"`
	Candidate        string      `json:"candidate"`
	Order            []string    `json:"order"`
}

func postRuleSet(w http.ResponseWriter, r *http.Request) {
	var request ruleSetRequest
	if err := decodeProfileSettings(r.Body, &request); err != nil {
		writeError(w, r, http.StatusBadRequest, errRuleSetInput)
		return
	}
	select {
	case ruleSetMutation <- struct{}{}:
		defer func() { <-ruleSetMutation }()
	default:
		writeError(w, r, http.StatusConflict, errProfileSettingsConflict)
		return
	}
	if err := changeRuleSet(r.Context(), request); err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, errProfileSettingsConflict) || errors.Is(err, errRuleSetInUse) {
			status = http.StatusConflict
		}
		writeError(w, r, status, err)
		return
	}
	render.NoContent(w, r)
}

func changeRuleSet(ctx context.Context, request ruleSetRequest) error {
	spec, ready := eng.ConfigSpec()
	home, catalog, generation := spec.Options.HomeDir, spec.Options.RuleSets, spec.Options.StoreGeneration
	ok := ready && request.BootID != "" && request.BootID == spec.BootID &&
		request.ExpectedRevision == catalog.Revision && request.Revision != request.ExpectedRevision
	if !ok {
		return errProfileSettingsConflict
	}
	if !ruleset.ValidID(request.Revision) {
		return errRuleSetInput
	}
	index := catalog.find(request.Item.ID)
	var previous ruleSetItem
	if index >= 0 {
		previous = catalog.Items[index]
	}
	next := ruleSetCatalog{Revision: request.Revision, Items: slices.Clone(catalog.Items)}
	contentChanged, committed := false, false
	switch request.Action {
	case "reorder":
		if len(request.Order) != len(catalog.Items) {
			return errRuleSetInput
		}
		for n, id := range request.Order {
			i := catalog.find(id)
			if i < 0 {
				return errRuleSetInput
			}
			next.Items[n] = catalog.Items[i]
		}
	case "delete":
		if index < 0 {
			return errProfileSettingsConflict
		}
		next.Items = slices.Delete(next.Items, index, index+1)
	case "save", "sync":
		item := request.Item
		if request.Action == "sync" {
			item = previous
			if item.URL == "" {
				return errRuleSetInput
			}
		}
		options := item
		if options.Format == "auto" {
			options.Format = "text"
		}
		if options.Behavior == "auto" {
			options.Behavior = "domain"
		}
		if !options.validOptions() || (index < 0 && len(catalog.Items) >= 100) {
			return errRuleSetInput
		}
		for _, other := range catalog.Items {
			if other.ID != item.ID && (other.Name == item.Name || (item.URL != "" && other.URL == item.URL)) {
				return errRuleSetInput
			}
		}
		item.Content, item.Count, item.UpdatedAt = previous.Content, previous.Count, previous.UpdatedAt
		if request.Action == "sync" || request.Candidate != "" || index < 0 || item.URL != previous.URL ||
			item.Behavior != previous.Behavior || item.Format != previous.Format {
			var err error
			item, contentChanged, err = prepareRuleSet(ctx, home, request, item, previous)
			if err != nil {
				return err
			}
		}
		if contentChanged {
			defer func() {
				if !committed {
					removeRuleSetFiles(home, item)
				}
			}()
		}
		if index < 0 {
			next.Items = append(next.Items, item)
		} else {
			next.Items[index] = item
		}
	default:
		return errRuleSetInput
	}
	if err := next.validate(); err != nil {
		return err
	}
	if encoded, err := json.Marshal(next); err != nil || len(encoded) >= profileSettingsLimit-1 {
		return errRuleSetInput
	}
	unlock, err := lockPortableStorage(home)
	if err != nil {
		return errProfileSettingsConflict
	}
	defer unlock()
	if generation != portableGeneration(home) {
		return errProfileSettingsConflict
	}
	if err := commitRuleSets(ctx, request, next, contentChanged); err != nil {
		return err
	}
	committed = true
	if previous.Content != "" && (request.Action == "delete" || contentChanged) {
		removeRuleSetFiles(home, previous)
	}
	return nil
}

func prepareRuleSet(ctx context.Context, home string, request ruleSetRequest, item, previous ruleSetItem) (ruleSetItem, bool, error) {
	var data []byte
	var err error
	switch {
	case request.Candidate != "" && item.URL == "":
		if !ruleset.ValidID(request.Candidate) {
			return item, false, errRuleSetInput
		}
		path := filepath.Join(home, "profile-work", request.Candidate+".ruleset")
		if _, statErr := os.Stat(path); errors.Is(statErr, os.ErrNotExist) {
			path = filepath.Join(home, "profiles", request.Candidate+".ruleset")
		}
		data, err = readRuleSetFile(path, ruleset.InputLimit)
	case item.URL != "" && (request.Action == "sync" || item.URL != previous.URL):
		data, err = downloadRuleSet(ctx, item.URL)
	case previous.Content != "":
		data, err = readRuleSetFile(previous.path(home, ".source"), ruleset.InputLimit)
	default:
		err = errRuleSetInput
	}
	if err != nil {
		return item, false, err
	}
	if item.Format == "auto" {
		item.Format = ruleset.DetectFormat(data)
	}
	behaviors := []string{item.Behavior}
	if item.Behavior == "auto" {
		behaviors = []string{"domain", "ipcidr", "classical"}
	}
	var compiled []byte
	var count int
	for _, behavior := range behaviors {
		compiled, count, err = ruleset.Compile(data, behavior, item.Format)
		if err == nil {
			item.Behavior = behavior
			break
		}
	}
	if err != nil {
		return item, false, err
	}
	item.UpdatedAt = time.Now().UnixMilli()
	if previous.Content != "" && item.Behavior == previous.Behavior && item.Format == previous.Format {
		if old, err := readRuleSetFile(previous.path(home, ".source"), ruleset.InputLimit); err == nil && bytes.Equal(old, data) {
			if _, err := os.Stat(previous.path(home, ".rules")); err == nil {
				return item, false, nil
			}
		}
	}
	if ctx.Err() != nil {
		return item, false, errProfileSettingsConflict
	}
	item.Content, item.Count = request.Revision, count
	if err := writeRuleSetFiles(home, item, data, compiled); err != nil {
		return item, false, err
	}
	return item, true, nil
}

func readRuleSetFile(path string, limit int) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, errProfileSettingsIO
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > int64(limit) {
		return nil, ruleset.ErrContent
	}
	data, err := io.ReadAll(io.LimitReader(file, int64(limit)+1))
	if err != nil || len(data) > limit {
		return nil, ruleset.ErrContent
	}
	return data, nil
}

func writeRuleSetFiles(home string, item ruleSetItem, source, compiled []byte) error {
	if os.MkdirAll(portableDataPath(home, "rule-sets"), 0700) != nil {
		return errProfileSettingsIO
	}
	sourcePath := item.path(home, ".source")
	if err := writeRuleSetFile(sourcePath, source); err != nil {
		return err
	}
	if err := writeRuleSetFile(item.path(home, ".rules"), compiled); err != nil {
		_ = os.Remove(sourcePath)
		return err
	}
	return nil
}

func writeRuleSetFile(path string, data []byte) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return errProfileSettingsIO
	}
	_, err = file.Write(data)
	if err == nil {
		err = file.Sync()
	}
	if err := errors.Join(err, file.Close()); err != nil {
		_ = os.Remove(path)
		return errProfileSettingsIO
	}
	return nil
}

func removeRuleSetFiles(home string, item ruleSetItem) {
	_ = os.Remove(item.path(home, ".source"))
	_ = os.Remove(item.path(home, ".rules"))
}

func commitRuleSets(ctx context.Context, request ruleSetRequest, catalog ruleSetCatalog, changed bool) error {
	return eng.withState(func(tx *stateTx) error {
		if ctx.Err() != nil || !profileSettingsCurrent(request.BootID, request.ExpectedRevision, eng.current.RuleSets.Revision, request.Revision) {
			return errProfileSettingsConflict
		}
		references := func(rule addedRule) bool { return rule.Kind == "RULE-SET" && rule.Payload == request.Item.ID }
		active := eng.current.Profile != "" && !eng.current.CustomRules &&
			slices.ContainsFunc(eng.current.AddedRules.effective(eng.current.ProfileRules), references)
		if request.Action == "delete" {
			if active || slices.ContainsFunc(eng.current.AddedRules.Rules, references) {
				return errRuleSetInUse
			}
			if len(eng.current.AddedRules.Profiles) > 0 {
				types, err := readProfileTypes(eng.current.HomeDir)
				if err != nil {
					return err
				}
				for _, profile := range eng.current.AddedRules.Profiles {
					kind, exists := types[profile.Profile]
					if (types == nil || exists && kind != "custom") && slices.ContainsFunc(profile.Rules, references) {
						return errRuleSetInUse
					}
				}
			}
		}
		path := ruleSetCatalogPath(eng.current.HomeDir)
		if active && changed {
			next := eng.current
			next.RuleSets = catalog
			return tx.CommitSettingsFile(next, path, catalog)
		}
		staged, err := stageProfileSettings(path, catalog)
		if err != nil {
			return err
		}
		defer os.Remove(staged)
		if err := os.Rename(staged, path); err != nil {
			return errProfileSettingsIO
		}
		next := eng.current
		next.RuleSets = catalog
		eng.setCurrentLocked(next)
		return nil
	})
}

func downloadRuleSet(ctx context.Context, source string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	ctx, finish := ruleRequestContext(ctx, nil)
	defer finish()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, source, nil)
	if err != nil {
		return nil, errRuleSetInput
	}
	transport, err := newRuleTransport()
	if err != nil {
		return nil, errRuleSetDownload
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, CheckRedirect: func(next *http.Request, via []*http.Request) error {
		if len(via) >= 10 || !validGeoURL(next.URL.String()) {
			return errRuleSetDownload
		}
		return nil
	}}
	response, err := client.Do(request)
	if err != nil {
		return nil, errRuleSetDownload
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, errRuleSetDownload
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, ruleset.InputLimit+1))
	if err != nil {
		return nil, errRuleSetDownload
	}
	if len(data) > ruleset.InputLimit {
		return nil, ruleset.ErrContent
	}
	return data, nil
}

func ensureRuleSetCompiled(home string, item ruleSetItem, path string) error {
	info, err := os.Stat(path)
	if err == nil && info.Mode().IsRegular() {
		return nil
	}
	data, err := readRuleSetFile(item.path(home, ".source"), ruleset.InputLimit)
	if err != nil {
		return errProfileSettingsIO
	}
	compiled, _, err := ruleset.Compile(data, item.Behavior, item.Format)
	if err != nil {
		return err
	}
	return writeRuleSetFile(path, compiled)
}
