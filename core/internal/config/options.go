// Package config 承载配置数据契约、磁盘读写校验、覆写组装与只读预览，零核心锁。
package config

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"

	"github.com/VOD-Studio/ArkClash/core/internal/backup"
	"github.com/VOD-Studio/ArkClash/core/internal/geo"
)

const ProfileSettingsLimit = 128 << 10

var (
	ErrSettingsInvalid  = errors.New("profile_settings_invalid")
	ErrSettingsConflict = errors.New("profile_settings_conflict")
	ErrSettingsIO       = errors.New("profile_settings_io")
	ErrSettingsApply    = errors.New("profile_settings_apply_failed")
	ErrSettingsListen   = errors.New("profile_settings_listen_failed")

	profileIDPattern = regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)
)

// VPN 进程传入启动设置；JSON 避免新增设置改变 C ABI，TUN 由独立操作附加。
// 嵌套切片和 map 遵循不可变约定：更新时整体替换，严禁原地修改。
type StartOptions struct {
	HomeDir    string `json:"homeDir"`
	ConfigPath string `json:"configPath"`
	Controller string `json:"controller"`
	Secret     string `json:"secret"`
	// 以下由 VPN 进程从 runtime.json 和配置列表（entry/src/main/ets/shared/）读出后传入。
	Profile  string `json:"profile"`  // 正在运行的配置的编号
	Mode     string `json:"mode"`     // 'rule' | 'global' | 'direct'，空串 = 用配置里的值
	AllowLan *bool  `json:"allowLan"` // nil = 用配置里的值
	// Geo 设置只由原生启动流程从磁盘读取，不扩展 C ABI 或 ArkTS 参数。
	Geo             geo.Settings        `json:"-"`
	General         GeneralSettings     `json:"-"`
	DNS             DNSOverrideSettings `json:"-"`
	AddedRules      AddedRulesSettings  `json:"-"`
	RuleSets        RuleSetCatalog      `json:"-"`
	Script          ProfileScript       `json:"-"`
	ProfileRules    ProfileAddedRules   `json:"-"`
	StoreGeneration string              `json:"-"`
	CustomRules     bool                `json:"-"`
	ContentHash     string              `json:"-"`
}

type SettingsRequest[T any] struct {
	BootID           string `json:"bootId"`
	ExpectedRevision string `json:"expectedRevision"`
	Settings         T      `json:"settings"`
}

type PreviewProfileMeta struct {
	Exists          bool
	Kind            string
	ContentRevision string
	UpdatedAt       int64
}

func ValidProfileID(id string) bool {
	return profileIDPattern.MatchString(id) && id != "." && id != ".."
}

// CheckProfilePath 校验配置路径仅允许位于 profiles 或 profile-work 目录下。
func CheckProfilePath(home, path string) error {
	if home == "" {
		return errors.New("invalid_profile_path")
	}
	dir := filepath.Dir(filepath.Clean(path))
	if dir != filepath.Join(home, "profiles") && dir != filepath.Join(home, "profile-work") {
		return errors.New("invalid_profile_path")
	}
	return nil
}

func DecodeSettings(r io.Reader, dst any) error {
	body, err := io.ReadAll(io.LimitReader(r, ProfileSettingsLimit+1))
	if err != nil || len(body) > ProfileSettingsLimit || !json.Valid(body) {
		return ErrSettingsInvalid
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(dst); err != nil {
		return ErrSettingsInvalid
	}
	return nil
}

func StageSettings(path string, value any) (string, error) {
	file, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+"-*.tmp")
	if err != nil {
		return "", ErrSettingsIO
	}
	encoder := json.NewEncoder(file)
	encoder.SetEscapeHTML(false)
	err = encoder.Encode(value)
	if err == nil {
		err = file.Sync()
	}
	if err = errors.Join(err, file.Close()); err != nil {
		_ = os.Remove(file.Name())
		return "", ErrSettingsIO
	}
	return file.Name(), nil
}

// LoadAll 从 opts.HomeDir 读取全量配置域设置与当前配置扩展信息。
func LoadAll(opts *StartOptions) error {
	opts.StoreGeneration = backup.Generation(opts.HomeDir)
	var err error
	if opts.Geo, err = geo.ReadSettings(opts.HomeDir); err != nil {
		return err
	}
	if opts.General, err = ReadGeneralSettings(opts.HomeDir); err != nil {
		return err
	}
	if opts.DNS, err = ReadDNSOverrides(opts.HomeDir); err != nil {
		return err
	}
	if opts.AddedRules, err = ReadAddedRules(opts.HomeDir); err != nil {
		return err
	}
	if opts.RuleSets, err = ReadRuleSets(opts.HomeDir); err != nil {
		return err
	}
	return LoadProfileExtension(opts)
}

func ReadProfileTypes(home string) (map[string]string, error) {
	file, err := os.Open(filepath.Join(home, "profiles", "list.json"))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, ErrSettingsIO
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
		return nil, ErrSettingsInvalid
	}
	types := make(map[string]string, len(list.Profiles))
	for _, item := range list.Profiles {
		types[item.ID] = item.Type
	}
	return types, nil
}

func ReadPreviewProfileMeta(home, profile string) (PreviewProfileMeta, error) {
	file, err := os.Open(filepath.Join(home, "profiles", "list.json"))
	if errors.Is(err, os.ErrNotExist) {
		return PreviewProfileMeta{}, nil
	}
	if err != nil {
		return PreviewProfileMeta{}, ErrSettingsIO
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
		return PreviewProfileMeta{}, ErrSettingsInvalid
	}
	for _, item := range list.Profiles {
		if item.ID == profile {
			return PreviewProfileMeta{
				Exists:          true,
				Kind:            item.Type,
				ContentRevision: item.ContentRevision,
				UpdatedAt:       item.UpdatedAt,
			}, nil
		}
	}
	return PreviewProfileMeta{Exists: false}, ErrPreviewNotFound
}
