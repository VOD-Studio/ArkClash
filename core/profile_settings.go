package main

import (
	"errors"
	"os"
	"path/filepath"

	corecfg "github.com/VOD-Studio/ArkClash/core/internal/config"
	"github.com/metacubex/mihomo/config"
)

func profileSettingsCurrent(bootID, expected, previous, next string) bool {
	return eng.running && bootID != "" && bootID == eng.bootID && expected == previous && next != expected
}

// CommitSettingsFile 统一执行设置文件暂存、按需热切换、原子改名与失败回滚。
func (tx *stateTx) CommitSettingsFile(next corecfg.StartOptions, path string, value any) error {
	e := tx.e
	if e.cleanupFailure != nil {
		return corecfg.ErrSettingsApply
	}
	previous := e.current
	previousInbound := e.desiredInbound
	var nextInbound inboundSettings
	var cfg *config.Config
	if next.Profile != "" {
		var err error
		cfg, err = parseProfileSettingsConfig(&next, &nextInbound)
		if errors.Is(err, corecfg.ErrDNSProxyServersRequired) || errors.Is(err, corecfg.ErrAddedRulesMatchTarget) {
			return err
		}
		if err != nil {
			return corecfg.ErrSettingsInvalid
		}
		if e.tun != nil && !dnsListenerAvailable(nextInbound.dnsListen, nextInbound.dnsMark) {
			return corecfg.ErrSettingsListen
		}
	}
	staged, err := corecfg.StageSettings(path, value)
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
		err = corecfg.ErrSettingsIO
	} else {
		err = corecfg.ErrSettingsApply
	}
	if !applied {
		return err
	}
	if tx.RollbackReload(previous, previousInbound) != nil {
		return corecfg.ErrSettingsApply
	}
	return err
}

func parseProfileSettingsConfig(options *corecfg.StartOptions, inbounds *inboundSettings) (*config.Config, error) {
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
