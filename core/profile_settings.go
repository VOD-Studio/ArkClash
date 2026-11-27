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
	return eng.running && bootID != "" && bootID == eng.bootID && expected == previous && next != expected
}

// CommitSettingsFile 统一执行设置文件暂存、按需热切换、原子改名与失败回滚。
func (tx *stateTx) CommitSettingsFile(next startOptions, path string, value any) error {
	e := tx.e
	if e.cleanupFailure != nil {
		return errProfileSettingsApply
	}
	previous := e.current
	previousInbound := e.desiredInbound
	var nextInbound inboundSettings
	var cfg *config.Config
	if next.Profile != "" {
		var err error
		cfg, err = parseProfileSettingsConfig(&next, &nextInbound)
		if errors.Is(err, errDNSProxyServersRequired) || errors.Is(err, errAddedRulesMatchTarget) {
			return err
		}
		if err != nil {
			return errProfileSettingsInvalid
		}
		if e.tun != nil && !dnsListenerAvailable(nextInbound.dnsListen, nextInbound.dnsMark) {
			return errProfileSettingsListen
		}
	}
	staged, err := stageProfileSettings(path, value)
	if err != nil {
		return err
	}
	defer os.Remove(staged)
	applied := false
	if cfg != nil {
		applied, err = tx.CommitReload(reloadPlan{
			Next:    next,
			Cfg:     cfg,
			Inbound: nextInbound,
		})
	}
	if err == nil {
		if err = os.Rename(staged, path); err == nil {
			if !applied {
				e.setCurrentLocked(next)
			}
			return nil
		}
		err = errProfileSettingsIO
	} else {
		err = errProfileSettingsApply
	}
	if !applied {
		return err
	}
	if tx.RollbackReload(previous, previousInbound) != nil {
		return errProfileSettingsApply
	}
	return err
}

func parseProfileSettingsConfig(options *startOptions, inbounds *inboundSettings) (*config.Config, error) {
	cfg, err := parseConfigWithInboundHash(options.ConfigPath, options, inbounds)
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
	return parseConfigWithInboundHash(path, options, inbounds)
}
