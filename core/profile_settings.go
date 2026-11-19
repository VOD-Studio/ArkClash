package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"

	"github.com/metacubex/mihomo/config"
)

const profileSettingsLimit = 128 << 10

var (
	errProfileSettingsInvalid  = errors.New("profile_settings_invalid")
	errProfileSettingsConflict = errors.New("profile_settings_conflict")
	errProfileSettingsIO       = errors.New("profile_settings_io")
	errProfileSettingsApply    = errors.New("profile_settings_apply_failed")
	errProfileSettingsListen   = errors.New("profile_settings_listen_failed")
)

type profileSettingsRequest[T any] struct {
	BootID           string `json:"bootId"`
	ExpectedRevision string `json:"expectedRevision"`
	Settings         T      `json:"settings"`
}

func decodeProfileSettings(r io.Reader, dst any) error {
	body, err := io.ReadAll(io.LimitReader(r, profileSettingsLimit+1))
	if err != nil || len(body) > profileSettingsLimit || !json.Valid(body) {
		return errProfileSettingsInvalid
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(dst); err != nil {
		return errProfileSettingsInvalid
	}
	return nil
}

func stageProfileSettings(path string, value any) (string, error) {
	file, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+"-*.tmp")
	if err != nil {
		return "", errProfileSettingsIO
	}
	encoder := json.NewEncoder(file)
	encoder.SetEscapeHTML(false)
	err = encoder.Encode(value)
	if err == nil {
		err = file.Sync()
	}
	if err = errors.Join(err, file.Close()); err != nil {
		_ = os.Remove(file.Name())
		return "", errProfileSettingsIO
	}
	return file.Name(), nil
}

func profileSettingsCurrent(bootID, expected, previous, next string) bool {
	return running && bootID != "" && bootID == runtimeBootID && expected == previous && next != expected
}

// 调用方持有 mu。退役诊断任务的等待回调须在解锁后调用。
func applyProfileSettingsLocked(next startOptions, path string, value any) (func(), error) {
	if cleanupFailure != nil {
		return nil, errProfileSettingsApply
	}
	previous := current
	var nextInbound inboundSettings
	var cfg *config.Config
	if next.Profile != "" {
		var err error
		cfg, err = parseProfileSettingsConfig(&next, &nextInbound)
		if err != nil {
			return nil, errProfileSettingsInvalid
		}
		if tunListener != nil && !dnsListenerAvailable(nextInbound.dnsListen, nextInbound.dnsMark) {
			return nil, errProfileSettingsListen
		}
	}
	staged, err := stageProfileSettings(path, value)
	if err != nil {
		return nil, err
	}
	defer os.Remove(staged)
	var wait func()
	if cfg != nil {
		wait, err = applyReloadLocked(next, cfg, nextInbound)
	}
	if err == nil {
		if err = os.Rename(staged, path); err == nil {
			current = next
			return wait, nil
		}
		err = errProfileSettingsIO
	} else {
		err = errProfileSettingsApply
	}
	if wait == nil {
		return nil, err
	}
	var previousInbound inboundSettings
	old, parseErr := parseProfileSettingsConfig(&previous, &previousInbound)
	if parseErr != nil {
		return wait, errProfileSettingsApply
	}
	waitRollback, rollbackErr := applyReloadLocked(previous, old, previousInbound)
	if rollbackErr != nil {
		err = errProfileSettingsApply
	}
	return func() {
		wait()
		if waitRollback != nil {
			waitRollback()
		}
	}, err
}

func parseProfileSettingsConfig(options *startOptions, inbounds *inboundSettings) (*config.Config, error) {
	cfg, err := parseConfigWithInbound(options.ConfigPath, *options, inbounds)
	// 订阅更新先加载候选，随后原子改名到正式路径。
	var missing *os.PathError
	if !errors.Is(err, os.ErrNotExist) || !errors.As(err, &missing) || missing.Path != options.ConfigPath ||
		filepath.Base(options.Profile) != options.Profile {
		return cfg, err
	}
	path := filepath.Join(options.HomeDir, "profiles", options.Profile+".yaml")
	if path == options.ConfigPath {
		return nil, err
	}
	options.ConfigPath = path
	return parseConfigWithInbound(path, *options, inbounds)
}
