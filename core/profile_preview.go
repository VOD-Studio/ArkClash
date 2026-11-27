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

	"github.com/VOD-Studio/ArkClash/core/internal/ruleset"
	"github.com/VOD-Studio/ArkClash/core/internal/script"
	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
	"go.yaml.in/yaml/v3"
)

// 预览 YAML 的输出上限，防止异常脚本展开超大配置占满内存。
const previewOutputLimit = 24 << 20

var (
	errPreviewCoreUnavailable = errors.New("preview_core_unavailable")
	errPreviewInvalidProfile  = errors.New("preview_invalid_profile")
	errPreviewNotFound        = errors.New("not_found")
	errPreviewInvalidYAML     = errors.New("invalid_yaml")
	errPreviewCustomTun       = errors.New("preview_custom_tun")
	errPreviewTooLarge        = errors.New("preview_too_large")
	errPreviewBuildFailed     = errors.New("preview_build_failed")
)

type profilePreviewResponse struct {
	Profile         string `json:"profile"`
	BootID          string `json:"bootId"`
	ConfigRevision  uint64 `json:"configRevision"`
	ContentRevision string `json:"contentRevision"`
	ContentHash     string `json:"contentHash"`
	Applied         bool   `json:"applied"`
	RunningProfile  string `json:"runningProfile"`
	CustomRules     bool   `json:"customRules"`
	ScriptIdentity  string `json:"scriptIdentity,omitempty"`
	YAML            string `json:"yaml"`
}

type previewProfileMeta struct {
	exists          bool
	kind            string
	contentRevision string
	updatedAt       int64
}

func readPreviewProfileMeta(home, profile string) (previewProfileMeta, error) {
	file, err := os.Open(filepath.Join(home, "profiles", "list.json"))
	if errors.Is(err, os.ErrNotExist) {
		return previewProfileMeta{}, nil
	}
	if err != nil {
		return previewProfileMeta{}, errProfileSettingsIO
	}
	defer file.Close()
	var list struct {
		Profiles []struct {
			ID              string `json:"id"`
			Type            string `json:"type"`
			ContentRevision string `json:"contentRevision"`
			UpdatedAt       int64  `json:"updatedAt"`
		} `json:"profiles"`
	}
	const limit = 8 << 20
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil || len(data) > limit || json.Unmarshal(data, &list) != nil {
		return previewProfileMeta{}, errProfileSettingsInvalid
	}
	for _, item := range list.Profiles {
		if item.ID == profile {
			return previewProfileMeta{
				exists:          true,
				kind:            item.Type,
				contentRevision: item.ContentRevision,
				updatedAt:       item.UpdatedAt,
			}, nil
		}
	}
	return previewProfileMeta{exists: false}, errPreviewNotFound
}

func getProfilePreview(w http.ResponseWriter, r *http.Request) {
	profile := r.URL.Query().Get("profile")
	if !addedRulesProfileID.MatchString(profile) || profile == "." || profile == ".." {
		writeError(w, r, http.StatusBadRequest, errPreviewInvalidProfile)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	response, err := buildProfilePreview(ctx, profile)
	if err != nil {
		status := http.StatusBadRequest
		switch {
		case errors.Is(err, errPreviewCoreUnavailable):
			status = http.StatusServiceUnavailable
		case errors.Is(err, errPreviewNotFound):
			status = http.StatusNotFound
		}
		writeError(w, r, status, err)
		return
	}
	render.JSON(w, r, response)
}

func buildProfilePreview(ctx context.Context, profile string) (profilePreviewResponse, error) {
	spec, ready := eng.ConfigSpec()
	if !ready {
		return profilePreviewResponse{}, errPreviewCoreUnavailable
	}
	base := spec.Options

	home := base.HomeDir
	meta, err := readPreviewProfileMeta(home, profile)
	if err != nil {
		return profilePreviewResponse{}, sanitizePreviewError(err)
	}

	previewOpts := startOptions{
		HomeDir:    home,
		ConfigPath: filepath.Join(home, "profiles", profile+".yaml"),
		Controller: base.Controller,
		Secret:     base.Secret,
		Profile:    profile,
		Mode:       base.Mode,
		AllowLan:   base.AllowLan,
	}
	if previewOpts.Geo, err = readGeoSettings(home); err != nil {
		return profilePreviewResponse{}, sanitizePreviewError(err)
	}
	if previewOpts.General, err = readGeneralSettings(home); err != nil {
		return profilePreviewResponse{}, sanitizePreviewError(err)
	}
	if previewOpts.DNS, err = readDNSOverrides(home); err != nil {
		return profilePreviewResponse{}, sanitizePreviewError(err)
	}
	if previewOpts.AddedRules, err = readAddedRules(home); err != nil {
		return profilePreviewResponse{}, sanitizePreviewError(err)
	}
	if previewOpts.RuleSets, err = readRuleSets(home); err != nil {
		return profilePreviewResponse{}, sanitizePreviewError(err)
	}
	if err := loadProfileExtension(&previewOpts); err != nil {
		return profilePreviewResponse{}, sanitizePreviewError(err)
	}
	if meta.kind == "custom" {
		previewOpts.CustomRules = true
	}

	rawCfg, hash, err := buildRawConfigWithHash(ctx, previewOpts.ConfigPath, previewOpts)
	if err != nil {
		return profilePreviewResponse{}, sanitizePreviewBuildError(err, previewOpts.Script.enabled())
	}
	if err := composeRawConfig(rawCfg, previewOpts); err != nil {
		return profilePreviewResponse{}, sanitizePreviewError(err)
	}
	// 内部控制面密钥仅用于同机 IPC，不暴露给预览页面或剪贴板。
	rawCfg.Secret = ""

	var out bytes.Buffer
	encoder := yaml.NewEncoder(&out)
	encoder.SetIndent(2)
	encodeErr := encoder.Encode(rawCfg)
	closeErr := encoder.Close()
	if encodeErr != nil || closeErr != nil {
		return profilePreviewResponse{}, errPreviewBuildFailed
	}
	if out.Len() > previewOutputLimit {
		return profilePreviewResponse{}, errPreviewTooLarge
	}

	var (
		applied        bool
		bootID         string
		configRevision uint64
		runningProfile string
	)
	if err := eng.withState(func(tx *stateTx) error {
		if !eng.running {
			return errPreviewCoreUnavailable
		}
		applied = previewMatchesCurrentLocked(previewOpts, hash)
		bootID = eng.bootID
		configRevision = eng.configRevision
		runningProfile = eng.current.Profile
		return nil
	}); err != nil {
		return profilePreviewResponse{}, err
	}

	shortHash := hash
	if len(shortHash) > 12 {
		shortHash = shortHash[:12]
	}
	return profilePreviewResponse{
		Profile:         profile,
		BootID:          bootID,
		ConfigRevision:  configRevision,
		ContentRevision: meta.contentRevision,
		ContentHash:     shortHash,
		Applied:         applied,
		RunningProfile:  runningProfile,
		CustomRules:     previewOpts.CustomRules,
		ScriptIdentity:  previewOpts.Script.identity,
		YAML:            out.String(),
	}, nil
}

// 调用方持有 eng.mu。核对已保存版本、脚本、规则与设置是否与当前运行内核一致。
func previewMatchesCurrentLocked(preview startOptions, previewHash string) bool {
	if !eng.running || eng.current.Profile == "" || eng.current.Profile != preview.Profile {
		return false
	}
	if eng.current.ContentHash != "" && previewHash != "" && eng.current.ContentHash != previewHash {
		return false
	}
	if eng.current.CustomRules != preview.CustomRules {
		return false
	}
	if !preview.CustomRules {
		if eng.current.Script.identity != preview.Script.identity ||
			eng.current.ProfileRules.Revision != preview.ProfileRules.Revision ||
			eng.current.AddedRules.Revision != preview.AddedRules.Revision ||
			eng.current.RuleSets.Revision != preview.RuleSets.Revision {
			return false
		}
	}
	return eng.current.DNS.Revision == preview.DNS.Revision &&
		eng.current.General.Revision == preview.General.Revision &&
		eng.current.Geo == preview.Geo
}

func sanitizePreviewBuildError(err error, scriptEnabled bool) error {
	if errors.Is(err, os.ErrNotExist) {
		return errPreviewNotFound
	}
	var scriptErr *script.Error
	if errors.As(err, &scriptErr) {
		return scriptErr
	}
	if errors.Is(err, errScriptConfig) || errors.Is(err, errScriptMissing) || errors.Is(err, errScriptStore) {
		return err
	}
	if scriptEnabled {
		return errScriptConfig
	}
	return errPreviewInvalidYAML
}

func sanitizePreviewError(err error) error {
	var scriptErr *script.Error
	if errors.As(err, &scriptErr) {
		return scriptErr
	}
	switch {
	case errors.Is(err, errPreviewCoreUnavailable),
		errors.Is(err, errPreviewInvalidProfile),
		errors.Is(err, errPreviewNotFound),
		errors.Is(err, errPreviewInvalidYAML),
		errors.Is(err, errPreviewTooLarge),
		errors.Is(err, errScriptMissing),
		errors.Is(err, errScriptStore),
		errors.Is(err, errScriptConfig),
		errors.Is(err, errAddedRulesMatchTarget),
		errors.Is(err, errDNSProxyServersRequired),
		errors.Is(err, errRuleSetInUse),
		errors.Is(err, errRuleSetInput),
		errors.Is(err, ruleset.ErrContent),
		errors.Is(err, errProfileSettingsInvalid),
		errors.Is(err, errProfileSettingsIO),
		errors.Is(err, errDNSInvalid),
		errors.Is(err, errDNSIO),
		errors.Is(err, errGeneralInvalid),
		errors.Is(err, errGeneralIO):
		return err
	case errors.Is(err, errCustomTunUnsupported):
		return errPreviewCustomTun
	default:
		return errPreviewBuildFailed
	}
}
