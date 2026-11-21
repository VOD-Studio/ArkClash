package backup

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
)

const StoreMarker = ".backup-store"

var requiredFiles = []string{"list.json", "scripts.json", "local-proxies.json", "icon-sets.json",
	"proxy-filters.json", "added-rules.json", "rule-sets.json"}

var settingFiles = []string{"dns-overrides.json", "general-settings.json", "geo-settings.json",
	"dashboard.json", "backup-settings.json", "portable-preferences.json"}

var defaults = map[string]string{
	"list.json":          `{"version":1,"current":"","profiles":[],"subscriptions":[]}`,
	"scripts.json":       `{"version":1,"scripts":[],"bindings":[]}`,
	"local-proxies.json": `{"version":1,"revision":"default","proxies":[]}`,
	"icon-sets.json":     `{"revision":"default","sets":[]}`,
	"proxy-filters.json": `{"revision":"default","presets":[]}`,
	"added-rules.json":   `{"revision":"default","rules":[],"profiles":[]}`,
	"rule-sets.json":     `{"revision":"default","items":[]}`,
}

var idPattern = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,120}$`)

func validID(s string) bool { return idPattern.MatchString(s) && !strings.HasPrefix(s, ".") }

func revision() string {
	var id [12]byte
	_, _ = rand.Read(id[:])
	return "b" + hex.EncodeToString(id[:])
}

func Generation(home string) string {
	data, _ := os.ReadFile(filepath.Join(home, "profiles", StoreMarker))
	return string(data)
}

func InStore(home string) bool {
	_, err := os.Stat(filepath.Join(home, "profiles", StoreMarker))
	return err == nil
}

func DataPath(home, name string) string {
	if InStore(home) {
		return filepath.Join(home, "profiles", name)
	}
	return filepath.Join(home, name)
}

func Snapshot(home, target string, settings bool) (string, error) {
	live := filepath.Join(home, "profiles")
	if err := os.MkdirAll(target, 0700); err != nil {
		return "", err
	}
	migrated := InStore(home)
	for i, name := range requiredFiles {
		base := live
		if !migrated && i >= len(requiredFiles)-2 {
			base = home
		}
		if err := capture(filepath.Join(base, name), filepath.Join(target, name), defaults[name]); err != nil {
			return "", err
		}
	}
	profiles, err := readObject(target, "list.json")
	if err != nil {
		return "", err
	}
	ids, err := entities(profiles, "profiles", "id")
	if err != nil {
		return "", err
	}
	for _, item := range ids {
		id := str(item, "id")
		for _, suffix := range []string{".yaml", ".selected.json"} {
			if err := capture(filepath.Join(live, id+suffix), filepath.Join(target, id+suffix), ""); err != nil {
				return "", err
			}
		}
		if _, err := os.Stat(filepath.Join(target, id+".yaml")); err != nil {
			return "", ErrInvalid
		}
	}
	subs, err := entities(profiles, "subscriptions", "id")
	if err != nil {
		return "", err
	}
	for _, item := range subs {
		name := str(item, "id") + ".state.json"
		if err := capture(filepath.Join(live, name), filepath.Join(target, name), ""); err != nil {
			return "", err
		}
	}
	catalog, err := readObject(target, "rule-sets.json")
	if err != nil {
		return "", err
	}
	rules, err := entities(catalog, "items", "id")
	if err != nil {
		return "", err
	}
	ruleHome := home
	if migrated {
		ruleHome = live
	}
	for _, item := range rules {
		name, err := ruleSource(item)
		if err != nil {
			return "", err
		}
		if err := capture(filepath.Join(ruleHome, name), filepath.Join(target, name), ""); err != nil {
			return "", err
		}
		if _, err := os.Stat(filepath.Join(target, name)); err != nil {
			return "", ErrInvalid
		}
	}
	if settings {
		for _, name := range settingFiles {
			if err := capture(DataPath(home, name), filepath.Join(target, name), ""); err != nil {
				return "", err
			}
		}
	}
	return revision(), nil
}

func capture(src, dst, fallback string) error {
	info, err := os.Lstat(src)
	if errors.Is(err, os.ErrNotExist) {
		if fallback == "" {
			return nil
		}
		return os.WriteFile(dst, []byte(fallback), 0600)
	}
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return ErrInvalid
	}
	if info.Size() >= maxFile {
		return ErrLimit
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0700); err != nil {
		return err
	}
	if err := os.Link(src, dst); err == nil {
		return nil
	}
	// 有的应用沙箱拒绝硬链接。复制期间仍持有写锁，保持清单与内容一致。
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	n, copyErr := io.Copy(out, io.LimitReader(in, maxFile))
	closeErr := out.Close()
	if n >= maxFile {
		return ErrLimit
	}
	return errors.Join(copyErr, closeErr)
}

type restoreResult struct {
	Current      string   `json:"current"`
	RemovedNames []string `json:"removedNames,omitempty"`
	Changes      bool     `json:"changes"`
	Removed      int      `json:"removed"`
	Profiles     int      `json:"profiles"`
	Revision     string   `json:"revision"`
	Settings     bool     `json:"settings"`
}

type collection struct {
	file  string
	key   string
	id    string
	label string
}

var collections = []collection{
	{"list.json", "profiles", "id", "name"}, {"list.json", "subscriptions", "id", ""},
	{"scripts.json", "scripts", "id", "name"}, {"scripts.json", "bindings", "profile", ""},
	{"local-proxies.json", "proxies", "id", "name"}, {"icon-sets.json", "sets", "id", "name"},
	{"proxy-filters.json", "presets", "id", "label"}, {"added-rules.json", "rules", "id", ""},
	{"added-rules.json", "profiles", "profile", ""}, {"rule-sets.json", "items", "id", "name"},
}

type object map[string]json.RawMessage

func readObject(root, file string) (object, error) {
	in, err := os.Open(filepath.Join(root, file))
	if err != nil {
		return nil, err
	}
	defer in.Close()
	limit := int64(4 << 20)
	switch file {
	case "scripts.json", "icon-sets.json":
		limit = 16 << 20
	case "rule-sets.json", "added-rules.json", "dns-overrides.json", "general-settings.json":
		limit = 128 << 10
	}
	data, err := io.ReadAll(io.LimitReader(in, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, ErrLimit
	}
	var result object
	if json.Unmarshal(data, &result) != nil || result == nil {
		return nil, ErrInvalid
	}
	return result, nil
}

func str(value object, field string) string {
	var s string
	_ = json.Unmarshal(value[field], &s)
	return s
}

func assign(value object, field string, v any) {
	value[field], _ = json.Marshal(v)
}

func entities(value object, field, id string) ([]object, error) {
	var out []object
	if field == "profiles" && id == "profile" && len(value[field]) == 0 {
		return []object{}, nil
	}
	if json.Unmarshal(value[field], &out) != nil || out == nil {
		return nil, ErrInvalid
	}
	seen := map[string]bool{}
	for _, item := range out {
		key := str(item, id)
		if !validID(key) || seen[key] {
			return nil, ErrInvalid
		}
		seen[key] = true
	}
	return out, nil
}

func ruleSource(item object) (string, error) {
	id, content := str(item, "id"), str(item, "content")
	if !validID(id) || !validID(content) {
		return "", ErrInvalid
	}
	return filepath.Join("rule-sets", id+"."+content+".source"), nil
}

func writeObject(root, file string, value object) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if len(data) >= maxFile {
		return ErrLimit
	}
	return os.WriteFile(filepath.Join(root, file), data, 0600)
}

func readBusiness(root string) (map[string]object, error) {
	out := make(map[string]object, len(requiredFiles))
	for _, name := range requiredFiles {
		value, err := readObject(root, name)
		if err != nil {
			return nil, err
		}
		if slices.Contains([]string{"list.json", "scripts.json", "local-proxies.json"}, name) &&
			string(value["version"]) != "1" {
			return nil, ErrVersion
		}
		out[name] = value
	}
	return out, nil
}

func planInputs(previous, imported string) (map[string]object, map[string]object, bool, error) {
	local, err := readBusiness(previous)
	if err != nil {
		return nil, nil, false, err
	}
	incoming, err := readBusiness(imported)
	if err != nil {
		return nil, nil, false, err
	}
	business := false
	for _, c := range collections {
		items, err := entities(incoming[c.file], c.key, c.id)
		if err != nil {
			return nil, nil, false, err
		}
		business = business || len(items) > 0
	}
	if err := checkReferences(imported, incoming); err != nil {
		return nil, nil, false, err
	}
	return local, incoming, business, nil
}

func Plan(previous, imported, target string, all, replace bool) (restoreResult, error) {
	local, incoming, business, err := planInputs(previous, imported)
	if err != nil {
		return restoreResult{}, err
	}
	if err := os.MkdirAll(target, 0700); err != nil {
		return restoreResult{}, err
	}
	result := restoreResult{Changes: business, Revision: revision()}
	for _, c := range collections {
		before, err := entities(local[c.file], c.key, c.id)
		if err != nil {
			return result, err
		}
		if !business {
			continue
		}
		after, _ := entities(incoming[c.file], c.key, c.id)
		for _, item := range after {
			if c.file == "list.json" && c.key == "profiles" {
				assign(item, "contentRevision", result.Revision)
			}
			if _, ok := item["revision"]; ok {
				assign(item, "revision", result.Revision)
			}
		}
		items, removed := merge(before, after, c, replace)
		if limit := collectionLimit(c); limit > 0 && len(items) > limit {
			return result, ErrLimit
		}
		result.Removed += removed
		if replace && c.label != "" && removed > 0 {
			kept := idSet(after, c.id)
			for _, item := range before {
				label := str(item, c.label)
				if label != "" && !kept[str(item, c.id)] && len(result.RemovedNames) < 12 {
					result.RemovedNames = append(result.RemovedNames, label)
				}
			}
		}
		assign(local[c.file], c.key, items)
	}
	if err := writePlan(previous, imported, target, all, business, local, incoming, &result); err != nil {
		return result, err
	}
	return result, nil
}

func collectionLimit(c collection) int {
	switch c.file {
	case "rule-sets.json":
		return 100
	case "local-proxies.json":
		return 5000
	case "proxy-filters.json":
		return 500
	case "added-rules.json":
		return 500
	default:
		return 0
	}
}

func merge(local, incoming []object, c collection, replace bool) ([]object, int) {
	out := make([]object, 0, len(local)+len(incoming))
	present := make(map[string]bool, len(incoming))
	for _, item := range incoming {
		present[str(item, c.id)] = true
		out = append(out, item)
	}
	removed := 0
	for _, item := range local {
		if !present[str(item, c.id)] {
			if replace {
				removed++
			} else {
				out = append(out, item)
			}
		}
	}
	if c.label != "" {
		deduplicateLabels(out, c.label)
	}
	return out, removed
}

func deduplicateLabels(items []object, label string) {
	seen := map[string]bool{}
	for _, item := range items {
		base := str(item, label)
		if base == "" {
			continue
		}
		name := base
		for n := 1; seen[name]; n++ {
			suffix := fmt.Sprintf("(%d)", n)
			runes := []rune(base)
			name = string(runes[:min(len(runes), 64-len(suffix))]) + suffix
		}
		if name != base {
			assign(item, label, name)
		}
		seen[name] = true
	}
}

func writePlan(previous, imported, target string, all, business bool, local, incoming map[string]object,
	result *restoreResult) error {
	list := local["list.json"]
	profiles, _ := entities(list, "profiles", "id")
	current := str(list, "current")
	if all && business {
		current = str(incoming["list.json"], "current")
	}
	if current == "" || !containsID(profiles, current) {
		if len(profiles) > 0 {
			current = str(profiles[0], "id")
		} else {
			current = ""
		}
	}
	result.Current, result.Profiles = current, len(profiles)
	if business {
		assign(list, "current", current)
	}
	for _, name := range requiredFiles {
		if business {
			if _, ok := local[name]["revision"]; ok || name == "list.json" {
				assign(local[name], "revision", result.Revision)
			}
		}
		if err := writeObject(target, name, local[name]); err != nil {
			return err
		}
	}
	if err := stageBlobs(previous, imported, target, business, local, incoming); err != nil {
		return err
	}
	for _, name := range settingFiles {
		from := previous
		if all {
			_, err := os.Stat(filepath.Join(imported, name))
			if err == nil {
				from, result.Settings = imported, true
			} else if !errors.Is(err, os.ErrNotExist) {
				return err
			} else if name != "backup-settings.json" && name != "portable-preferences.json" {
				continue
			}
		}
		if from == imported {
			document, err := readObject(from, name)
			if err != nil {
				return err
			}
			switch name {
			case "dashboard.json":
				delete(document, "legacyPreferences")
			case "portable-preferences.json":
				assign(document, "revision", result.Revision)
			default:
				if _, exists := document["revision"]; exists {
					assign(document, "revision", result.Revision)
				}
			}
			if err := writeObject(target, name, document); err != nil {
				return err
			}
		} else if err := capture(filepath.Join(from, name), filepath.Join(target, name), ""); err != nil {
			return err
		}
	}
	return checkReferences(target, local)
}

func stageBlobs(previous, imported, target string, business bool, local, incoming map[string]object) error {
	for _, group := range []struct {
		file, key string
		suffixes  []string
	}{
		{"list.json", "profiles", []string{".yaml", ".selected.json"}},
		{"list.json", "subscriptions", []string{".state.json"}},
		{"rule-sets.json", "items", nil},
	} {
		items, _ := entities(local[group.file], group.key, "id")
		other, _ := entities(incoming[group.file], group.key, "id")
		inIDs := idSet(other, "id")
		for _, item := range items {
			id := str(item, "id")
			from := previous
			if business && inIDs[id] {
				from = imported
			}
			if group.suffixes == nil {
				name, err := ruleSource(item)
				if err != nil {
					return err
				}
				if err := capture(filepath.Join(from, name), filepath.Join(target, name), ""); err != nil {
					return err
				}
			}
			for _, suffix := range group.suffixes {
				name := id + suffix
				if err := capture(filepath.Join(from, name), filepath.Join(target, name), ""); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

func containsID(items []object, id string) bool {
	return slices.ContainsFunc(items, func(item object) bool { return str(item, "id") == id })
}

func idSet(items []object, field string) map[string]bool {
	out := make(map[string]bool, len(items))
	for _, item := range items {
		out[str(item, field)] = true
	}
	return out
}

func checkReferences(root string, records map[string]object) error {
	list := records["list.json"]
	profiles, _ := entities(list, "profiles", "id")
	profileIDs := idSet(profiles, "id")
	subs, _ := entities(list, "subscriptions", "id")
	subIDs := idSet(subs, "id")
	if current := str(list, "current"); current != "" && !profileIDs[current] {
		return ErrInvalid
	}
	for _, item := range profiles {
		sub := str(item, "subscription")
		var name string
		var edited bool
		var subscription string
		if (sub != "" && !subIDs[sub]) || json.Unmarshal(item["name"], &name) != nil ||
			json.Unmarshal(item["nameEdited"], &edited) != nil || json.Unmarshal(item["subscription"], &subscription) != nil {
			return ErrInvalid
		}
		id := str(item, "id")
		if _, err := os.Stat(filepath.Join(root, id+".yaml")); err != nil {
			return ErrInvalid
		}
		if data, err := os.ReadFile(filepath.Join(root, id+".selected.json")); err == nil {
			var selected map[string]string
			if json.Unmarshal(data, &selected) != nil || selected == nil {
				return ErrInvalid
			}
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	rules, _ := entities(records["rule-sets.json"], "items", "id")
	ruleIDs := idSet(rules, "id")
	ruleURLs := map[string]bool{}
	for _, item := range rules {
		name, err := ruleSource(item)
		if err != nil {
			return err
		}
		if url := str(item, "url"); url != "" {
			if ruleURLs[url] {
				return ErrInvalid
			}
			ruleURLs[url] = true
		}
		if _, err := os.Stat(filepath.Join(root, name)); err != nil {
			return ErrInvalid
		}
	}
	ruleSets := records["added-rules.json"]
	items, _ := entities(ruleSets, "rules", "id")
	attachments, _ := entities(ruleSets, "profiles", "profile")
	for _, attachment := range attachments {
		if !profileIDs[str(attachment, "profile")] {
			return ErrInvalid
		}
		attached, err := entities(attachment, "rules", "id")
		if err != nil {
			return err
		}
		items = append(items, attached...)
	}
	for _, rule := range items {
		if str(rule, "kind") == "RULE-SET" && !ruleIDs[str(rule, "payload")] {
			return ErrInvalid
		}
	}
	bindings, _ := entities(records["scripts.json"], "bindings", "profile")
	for _, item := range bindings {
		if !profileIDs[str(item, "profile")] {
			return ErrInvalid
		}
	}
	return nil
}

func unchanged(previous, fresh string) (bool, error) {
	before, err := scanFiles(previous)
	if err != nil {
		return false, err
	}
	after, err := scanFiles(fresh)
	if err != nil || !slices.Equal(before, after) {
		return false, err
	}
	for _, name := range before {
		a, err := os.Stat(filepath.Join(previous, name))
		if err != nil {
			return false, err
		}
		b, err := os.Stat(filepath.Join(fresh, name))
		if err != nil {
			return false, err
		}
		if !os.SameFile(a, b) {
			if a.Size() != b.Size() {
				return false, nil
			}
			_, beforeHash, beforeErr := archiveFile(previous, name, io.Discard)
			_, afterHash, afterErr := archiveFile(fresh, name, io.Discard)
			if err := errors.Join(beforeErr, afterErr); err != nil || beforeHash != afterHash {
				return false, err
			}
		}
	}
	return true, nil
}

func PrepareCommit(home, previous, fresh string) error {
	if _, err := Snapshot(home, fresh, true); err != nil {
		return err
	}
	ok, err := unchanged(previous, fresh)
	if err != nil {
		return err
	}
	if !ok {
		return ErrChanged
	}
	return nil
}

func Seal(target, revision string) error {
	if !validID(revision) {
		return ErrInvalid
	}
	if err := os.WriteFile(filepath.Join(target, StoreMarker), []byte(revision), 0600); err != nil {
		return err
	}
	return syncTree(target)
}

func syncTree(root string) error {
	return filepath.WalkDir(root, func(name string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		f, err := os.Open(name)
		if err != nil {
			return err
		}
		return errors.Join(f.Sync(), f.Close())
	})
}
