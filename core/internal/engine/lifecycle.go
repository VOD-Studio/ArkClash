package engine

import (
	"context"
	"errors"
	"fmt"
	"strings"

	corecfg "github.com/VOD-Studio/ArkClash/core/internal/config"
	"github.com/VOD-Studio/ArkClash/core/internal/geo"
	"github.com/VOD-Studio/ArkClash/core/internal/providers"
	"github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/listener"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/ntp/ntp"
	"github.com/metacubex/mihomo/tunnel"
)

func (e *Engine) Start(opts corecfg.StartOptions) error {
	return e.withLifecycle(func(tx *stateTx) error {
		if e.running {
			return errors.New("core is already running")
		}
		if e.tun != nil || e.vpnCreated {
			return errors.New("previous VPN resources are not released")
		}
		if e.cleanupFailure != nil {
			return e.cleanupFailure
		}
		inbound.EnableArkClashListenerOwnership()
		if err := tunnel.ArkClashSuspendForwarding(); err != nil {
			e.cleanupFailure = errors.Join(e.cleanupFailure, err)
			return e.cleanupFailure
		}
		if err := corecfg.LoadAll(&opts); err != nil {
			return err
		}

		e.installRuleProviderReuse()
		e.publishRuleProvidersLocked(nil, nil)
		constant.SetHomeDir(opts.HomeDir)
		constant.SetConfig(opts.ConfigPath)

		var nextInbound inboundSettings
		cfg, err := parseConfigWithInboundHash(opts.ConfigPath, &opts, &nextInbound)
		if err != nil {
			return err
		}
		e.desiredInbound = nextInbound
		if err := route.ArkClashReCreateServer(&route.Config{
			Addr: cfg.Controller.ExternalController, Secret: cfg.Controller.Secret,
			RoutingMark: cfg.Controller.ExternalControllerRoutingMark,
			DohServer:   cfg.Controller.ExternalDohServer,
			Cors: route.Cors{AllowOrigins: cfg.Controller.Cors.AllowOrigins,
				AllowPrivateNetwork: cfg.Controller.Cors.AllowPrivateNetwork},
		}); err != nil {
			e.desiredInbound = inboundSettings{}
			return err
		}
		executor.ApplyConfig(withoutBusinessInbounds(cfg), true)
		e.publishRuleProvidersLocked(cfg, nextInbound.ruleProviderKeys)

		e.running = true
		e.current = opts
		tx.deferUnlock(e.beginRuntimeLocked())
		manager, err := geo.NewManager(opts.HomeDir, e.bootID, opts.Geo, e.CommitGeoSwap)
		if err != nil {
			tx.deferUnlock(e.diag.Stop())
			e.closeCoreListenersLocked()
			executor.Shutdown()
			e.cleanupFailure = errors.Join(e.cleanupFailure, route.ArkClashCloseServer())
			tunnel.OnSuspend()
			tunnel.UpdateProxies(nil, nil)
			tunnel.UpdateRules(nil, nil, nil)
			e.publishRuleProvidersLocked(nil, nil)
			e.running = false
			e.current = corecfg.StartOptions{}
			e.desiredInbound = inboundSettings{}
			e.publishRuntimeLocked()
			return errors.Join(err, e.cleanupFailure)
		}
		e.geo.Store(manager)
		if opts.General.ControllerSecret != "" {
			if err := e.setPanelControllerLocked(opts.General.ControllerSecret); err != nil {
				log.Warnln("[ArkClash] external controller port unavailable")
			}
		}
		e.resetProxyIdentitiesLocked()
		e.watchRuntimeRoutesLocked(cfg)
		e.providers.Reset(providers.Identity{
			BootID: e.bootID, ConfigRevision: e.configRevision, Profile: e.current.Profile, HomeDir: e.current.HomeDir,
		}, cfg)
		e.publishRuntimeLocked()
		log.Infoln("[ArkClash] core started")
		return nil
	})
}

func ParseConfig(path string, opts corecfg.StartOptions) (*config.Config, error) {
	return parseConfigWithInbound(path, opts, nil)
}

func parseConfigWithInbound(path string, opts corecfg.StartOptions, settings *inboundSettings) (*config.Config, error) {
	return parseConfigWithInboundHash(path, &opts, settings)
}

func parseConfigWithInboundHash(path string, opts *corecfg.StartOptions, settings *inboundSettings) (*config.Config, error) {
	rawCfg, hash, err := corecfg.BuildRawConfigWithHash(context.Background(), path, *opts)
	if err != nil {
		return nil, err
	}
	opts.ContentHash = hash
	cfg, err := prepareRawConfig(rawCfg, *opts, settings)
	if err != nil && opts.Script.Enabled() && !errors.Is(err, corecfg.ErrDNSProxyServersRequired) &&
		!errors.Is(err, corecfg.ErrAddedRulesMatchTarget) {
		return nil, corecfg.ErrScriptConfig
	}
	return cfg, err
}

func prepareRawConfig(rawCfg *config.RawConfig, opts corecfg.StartOptions, settings *inboundSettings) (*config.Config, error) {
	var baseline corecfg.GeneralBaseline
	if settings != nil {
		baseline = corecfg.CaptureGeneralBaseline(rawCfg, opts)
	}
	if err := corecfg.ComposeRawConfig(rawCfg, opts); err != nil {
		return nil, err
	}
	if settings != nil {
		baseline.SetRawDNSFlags(rawCfg.DNS.RespectRules, rawCfg.DNS.FakeIPRange6 != "")
	}
	// 配置解析可能初始化缺失的 Geo，来源必须先固定为页面设置。
	geo.SetURLs(opts.Geo)
	mappings := rawCfg.Listeners
	var providerKeys map[string]string
	if settings != nil {
		providerKeys = ruleProviderKeys(rawCfg.RuleProvider)
	}
	cfg, err := config.ParseRawConfig(rawCfg)
	if err != nil {
		return nil, err
	}
	if opts.Profile != "" {
		if err := RestoreSelections(cfg, opts); err != nil {
			return nil, err
		}
	}
	if settings != nil {
		baseline.FinalizeDNS(cfg.DNS, opts.Profile != "" && opts.General.AppendSystemDNS)
		*settings = captureInbound(cfg, mappings)
		settings.baseline = baseline
		settings.ruleProviderKeys = providerKeys
	}
	return cfg, nil
}

// Reload 是热切换：解析 path，成功后换用新配置，profile 记为正在运行的配置。
// 只调 executor.ApplyConfig，不走 hub.ApplyConfig：后者的 applyRoute 每次都会关掉 controller
// 再重开，掐断发起热切换的请求和界面的 WebSocket（ADR-0010）。controller 的地址和 secret
// 由 ApplyOverrides 固定，不需要重建。改 Start 的解析和应用流程时，这里要一起看。
func (e *Engine) Reload(path, profile string, expectedProfile *string) error {
	return e.withState(func(tx *stateTx) error {
		if !e.running {
			return errors.New("core is not running")
		}
		if expectedProfile != nil && e.current.Profile != *expectedProfile {
			return errors.New("profile_changed")
		}
		if profile == "" {
			if path != "" || e.tun != nil || e.vpnCreated || businessListenersOpen() || e.cleanupFailure != nil {
				return errors.New("empty profile requires a fully detached core")
			}
		} else if err := corecfg.CheckProfilePath(e.current.HomeDir, path); err != nil {
			return err
		}
		next := e.current
		next.Profile = profile
		next.ConfigPath = path
		if err := corecfg.LoadProfileExtension(&next); err != nil {
			return err
		}
		var nextInbound inboundSettings
		cfg, err := parseConfigWithInboundHash(path, &next, &nextInbound)
		if err != nil {
			return err
		}
		_, err = tx.CommitReload(reloadPlan{Next: next, Cfg: cfg, Inbound: nextInbound})
		return err
	})
}

// 推给界面的「热切换完成」事件，格式和 entry/src/main/ets/client/ 里的解析一致。
type reloadedEvent struct {
	Type    string `json:"type"`
	Profile string `json:"profile"`
}

func (e *Engine) RunningProfile() (string, bool) {
	v := e.View()
	if v == nil || !v.Status.Running {
		return "", false
	}
	return v.Status.Profile, true
}

// SetRuntimeOptions 立即修改出站模式和局域网代理，并记下来供之后的热切换使用。
func (e *Engine) SetRuntimeOptions(mode *string, allowLan *bool) error {
	return e.withState(func(tx *stateTx) error {
		if !e.running {
			return errors.New("core is not running")
		}
		if mode != nil {
			m, ok := tunnel.ModeMapping[strings.ToLower(*mode)]
			if !ok {
				return fmt.Errorf("unknown mode %q", *mode)
			}
			tunnel.SetMode(m)
			e.current.Mode = *mode
		}
		if allowLan != nil {
			e.desiredInbound.inbound.AllowLan = *allowLan
			listener.SetAllowLan(*allowLan)
			v := *allowLan
			e.current.AllowLan = &v
		}
		e.publishRuntimeLocked()
		return nil
	})
}

type AttachIdentity struct {
	BootID         string
	Profile        string
	ConfigRevision uint64
}

type TunNetworkOptions struct {
	Stack                string
	IPv6                 bool
	DNSHijacking         bool
	MTU                  int
	CongestionController string
}

func (e *Engine) AttachTun(fd int, network TunNetworkOptions, expected AttachIdentity) error {
	return e.withLifecycle(func(tx *stateTx) error {
		if !e.running {
			return errors.New("core is not running")
		}
		if expected.BootID != e.bootID || expected.Profile != e.current.Profile ||
			expected.ConfigRevision != e.configRevision {
			return errors.New("stale_attach_identity")
		}
		if e.current.Profile == "" || e.current.ConfigPath == "" {
			return errors.New("no profile is loaded")
		}
		if fd <= 0 {
			return errors.New("invalid tun fd")
		}
		if e.tun != nil {
			if e.cleanupFailure != nil {
				return e.cleanupFailure
			}
			return nil
		}
		if e.cleanupFailure != nil {
			return e.cleanupFailure
		}
		if err := e.startTunLocked(fd, network); err != nil {
			// 平台构造器必须自行回滚未发布资源；已发布的 listener 仍由这里收尾。
			var cleanupErr error
			if e.tun != nil {
				cleanupErr = e.stopTunLocked()
			}
			e.cleanupFailure = errors.Join(e.cleanupFailure, cleanupErr)
			e.publishRuntimeLocked()
			return errors.Join(err, e.cleanupFailure)
		}
		if err := e.restoreBusinessInboundsLocked(); err != nil {
			e.cleanupFailure = errors.Join(e.cleanupFailure, closeBusinessInbounds(), e.stopTunLocked())
			e.publishRuntimeLocked()
			return errors.Join(err, e.cleanupFailure)
		}
		e.publishRuntimeLocked()
		return nil
	})
}

func (e *Engine) DetachTun() error {
	return e.withLifecycle(func(tx *stateTx) error {
		err := errors.Join(closeBusinessInbounds(), e.stopTunLocked())
		e.cleanupFailure = errors.Join(e.cleanupFailure, err)
		// URLTest 直接拨指定节点，不登记到转发 tracker，断开不能取消其上下文。
		resolver.ResetConnection()
		e.publishRuntimeLocked()
		return e.cleanupFailure
	})
}

func (e *Engine) closeCoreListenersLocked() {
	e.cleanupFailure = errors.Join(e.cleanupFailure, closeBusinessInbounds())
	ntp.ReCreateNTPService("", 0, "", nil, false)
}

func (e *Engine) Stop() error {
	return e.withLifecycle(func(tx *stateTx) error {
		_ = e.setPanelControllerLocked("")
		e.closeCoreListenersLocked()
		if !e.running && e.tun == nil && !businessListenersOpen() {
			_ = e.updateVpnStateLocked("stopped", "stopped", e.vpnCreated)
			return e.cleanupFailure
		}
		tx.deferUnlock(e.diag.Stop())
		manager := e.geo.Swap(nil)
		if manager != nil {
			manager.Close()
			// worker 的热换提交可能需要核心锁，且下一次 Start 不得越过本次 join。
			tx.deferUnlock(manager.Wait)
		}
		tx.deferUnlock(e.providers.Close())
		e.resetProxyIdentitiesLocked()
		e.stopRuntimeRoutesLocked()
		e.cancelDelayTestsLocked()
		e.cleanupFailure = errors.Join(e.cleanupFailure, e.stopTunLocked())
		resolver.ResetConnection()
		executor.Shutdown()
		e.cleanupFailure = errors.Join(e.cleanupFailure, route.ArkClashCloseServer())
		tunnel.OnSuspend()
		tunnel.UpdateProxies(nil, nil)
		tunnel.UpdateRules(nil, nil, nil)
		tunnel.UpdateListeners(nil)
		e.publishRuleProvidersLocked(nil, nil)
		e.running = false
		e.current = corecfg.StartOptions{}
		e.desiredInbound = inboundSettings{}
		if err := e.updateVpnStateLocked("stopped", "stopped", e.vpnCreated); err != nil {
			log.Errorln("[ArkClash] core stopped with pending VPN resources: %s", err)
		}
		return e.cleanupFailure
	})
}
