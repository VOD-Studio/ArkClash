package config

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/VOD-Studio/ArkClash/core/internal/backup"
	"github.com/VOD-Studio/ArkClash/core/internal/geo"
	"github.com/VOD-Studio/ArkClash/core/internal/ruleset"
	"github.com/VOD-Studio/ArkClash/core/internal/ruletunnel"
	"github.com/metacubex/http"
	mihomoConfig "github.com/metacubex/mihomo/config"
)

var (
	ErrRuleSetInput    = errors.New("rule_set_input")
	ErrRuleSetDownload = errors.New("rule_set_download")
	ErrRuleSetInUse    = errors.New("rule_set_in_use")
)

type RuleSetItem struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	URL       string `json:"url"`
	Behavior  string `json:"behavior"`
	Format    string `json:"format"`
	Content   string `json:"content"`
	Count     int    `json:"count"`
	UpdatedAt int64  `json:"updatedAt"`
}

type RuleSetCatalog struct {
	Revision string        `json:"revision"`
	Items    []RuleSetItem `json:"items"`
}

type RuleSetRequest struct {
	BootID           string      `json:"bootId"`
	ExpectedRevision string      `json:"expectedRevision"`
	Revision         string      `json:"revision"`
	Action           string      `json:"action"`
	Item             RuleSetItem `json:"item"`
	Candidate        string      `json:"candidate"`
	Order            []string    `json:"order"`
}

func ValidRuleSetRevision(revision string) bool {
	return ruleset.ValidID(revision)
}

func (s RuleSetItem) ValidOptions() bool {
	if !ruleset.ValidID(s.ID) || s.Name == "" || len(s.Name) > 256 ||
		strings.TrimSpace(s.Name) != s.Name || strings.ContainsAny(s.Name, "\x00\r\n") ||
		(s.URL != "" && !geo.ValidURL(s.URL)) {
		return false
	}
	switch s.Behavior {
	case "domain", "ipcidr", "classical":
	default:
		return false
	}
	return s.Format == "text" || s.Format == "yaml" || (s.Format == "mrs" && s.Behavior != "classical")
}

func (c RuleSetCatalog) Validate() error {
	if !ruleset.ValidID(c.Revision) || c.Items == nil || len(c.Items) > 100 {
		return ErrRuleSetInput
	}
	ids, names, urls := map[string]bool{}, map[string]bool{}, map[string]bool{}
	for _, item := range c.Items {
		if !item.ValidOptions() || !ruleset.ValidID(item.Content) || item.Count < 1 ||
			item.Count > ruleset.LineLimit || item.UpdatedAt < 1 || ids[item.ID] || names[item.Name] ||
			(item.URL != "" && urls[item.URL]) {
			return ErrRuleSetInput
		}
		ids[item.ID], names[item.Name], urls[item.URL] = true, true, true
	}
	return nil
}

func (c RuleSetCatalog) Find(id string) int {
	return slices.IndexFunc(c.Items, func(item RuleSetItem) bool { return item.ID == id })
}

func RuleSetCatalogPath(home string) string { return backup.DataPath(home, "rule-sets.json") }

func (s RuleSetItem) Path(home, suffix string) string {
	return filepath.Join(backup.DataPath(home, "rule-sets"), s.ID+"."+s.Content+suffix)
}

func ReadRuleSets(home string) (RuleSetCatalog, error) {
	file, err := os.Open(RuleSetCatalogPath(home))
	if errors.Is(err, os.ErrNotExist) {
		return RuleSetCatalog{Revision: "default", Items: []RuleSetItem{}}, nil
	}
	if err != nil {
		return RuleSetCatalog{}, ErrSettingsIO
	}
	defer file.Close()
	var catalog RuleSetCatalog
	if err := DecodeSettings(file, &catalog); err != nil {
		return catalog, err
	}
	return catalog, catalog.Validate()
}

func (c RuleSetCatalog) Attach(raw *mihomoConfig.RawConfig, home string, rules []AddedRule) error {
	var attached map[string]bool
	for _, item := range rules {
		if item.Kind != "RULE-SET" || attached[item.Payload] {
			continue
		}
		i := c.Find(item.Payload)
		if i < 0 {
			return ErrRuleSetInUse
		}
		entry := c.Items[i]
		path := entry.Path(home, ".rules")
		if err := EnsureRuleSetCompiled(home, entry, path); err != nil {
			return err
		}
		name := ruleset.ManagedName(entry.ID)
		if raw.RuleProvider == nil {
			raw.RuleProvider = make(map[string]map[string]any)
		}
		if _, exists := raw.RuleProvider[name]; exists {
			return ErrRuleSetInput
		}
		raw.RuleProvider[name] = map[string]any{"type": "file", "path": path, "format": "text", "behavior": entry.Behavior}
		if attached == nil {
			attached = make(map[string]bool)
		}
		attached[entry.ID] = true
	}
	return nil
}

func PrepareRuleSet(ctx context.Context, home string, request RuleSetRequest, item, previous RuleSetItem) (RuleSetItem, bool, error) {
	var data []byte
	var err error
	switch {
	case request.Candidate != "" && item.URL == "":
		if !ruleset.ValidID(request.Candidate) {
			return item, false, ErrRuleSetInput
		}
		path := filepath.Join(home, "profile-work", request.Candidate+".ruleset")
		if _, statErr := os.Stat(path); errors.Is(statErr, os.ErrNotExist) {
			path = filepath.Join(home, "profiles", request.Candidate+".ruleset")
		}
		data, err = readRuleSetFile(path, ruleset.InputLimit)
	case item.URL != "" && (request.Action == "sync" || item.URL != previous.URL):
		data, err = DownloadRuleSet(ctx, item.URL)
	case previous.Content != "":
		data, err = readRuleSetFile(previous.Path(home, ".source"), ruleset.InputLimit)
	default:
		err = ErrRuleSetInput
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
		if old, err := readRuleSetFile(previous.Path(home, ".source"), ruleset.InputLimit); err == nil && bytes.Equal(old, data) {
			if _, err := os.Stat(previous.Path(home, ".rules")); err == nil {
				return item, false, nil
			}
		}
	}
	if ctx.Err() != nil {
		return item, false, ErrSettingsConflict
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
		return nil, ErrSettingsIO
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

func writeRuleSetFiles(home string, item RuleSetItem, source, compiled []byte) error {
	if os.MkdirAll(backup.DataPath(home, "rule-sets"), 0700) != nil {
		return ErrSettingsIO
	}
	sourcePath := item.Path(home, ".source")
	if err := writeRuleSetFile(sourcePath, source); err != nil {
		return err
	}
	if err := writeRuleSetFile(item.Path(home, ".rules"), compiled); err != nil {
		_ = os.Remove(sourcePath)
		return err
	}
	return nil
}

func writeRuleSetFile(path string, data []byte) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return ErrSettingsIO
	}
	_, err = file.Write(data)
	if err == nil {
		err = file.Sync()
	}
	if err := errors.Join(err, file.Close()); err != nil {
		_ = os.Remove(path)
		return ErrSettingsIO
	}
	return nil
}

func RemoveRuleSetFiles(home string, item RuleSetItem) {
	_ = os.Remove(item.Path(home, ".source"))
	_ = os.Remove(item.Path(home, ".rules"))
}

func DownloadRuleSet(ctx context.Context, source string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	ctx, finish := ruletunnel.RequestContext(ctx, nil)
	defer finish()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, source, nil)
	if err != nil {
		return nil, ErrRuleSetInput
	}
	transport, err := ruletunnel.NewTransport()
	if err != nil {
		return nil, ErrRuleSetDownload
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, CheckRedirect: func(next *http.Request, via []*http.Request) error {
		if len(via) >= 10 || !geo.ValidURL(next.URL.String()) {
			return ErrRuleSetDownload
		}
		return nil
	}}
	response, err := client.Do(request)
	if err != nil {
		return nil, ErrRuleSetDownload
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, ErrRuleSetDownload
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, ruleset.InputLimit+1))
	if err != nil {
		return nil, ErrRuleSetDownload
	}
	if len(data) > ruleset.InputLimit {
		return nil, ruleset.ErrContent
	}
	return data, nil
}

func EnsureRuleSetCompiled(home string, item RuleSetItem, path string) error {
	info, err := os.Stat(path)
	if err == nil && info.Mode().IsRegular() {
		return nil
	}
	data, err := readRuleSetFile(item.Path(home, ".source"), ruleset.InputLimit)
	if err != nil {
		return ErrSettingsIO
	}
	compiled, _, err := ruleset.Compile(data, item.Behavior, item.Format)
	if err != nil {
		return err
	}
	return writeRuleSetFile(path, compiled)
}
