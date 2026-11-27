package main

import (
	"context"
	"errors"
	"fmt"
	"strings"

	corecfg "github.com/VOD-Studio/ArkClash/core/internal/config"
	"github.com/VOD-Studio/ArkClash/core/internal/geo"
	"github.com/VOD-Studio/ArkClash/core/internal/providers"
	"github.com/VOD-Studio/ArkClash/core/internal/subfetch"
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

func start(opts corecfg.StartOptions) error {
	return eng.withLifecycle(func(tx *stateTx) error {
		if eng.running {
			return errors.New("core is already running")
		}
		if eng.tun != nil || eng.vpnCreated {
			return errors.New("previous VPN resources are not released")
		}
		if eng.cleanupFailure != nil {
			return eng.cleanupFailure
		}
		inbound.EnableArkClashListenerOwnership()
		if err := tunnel.ArkClashSuspendForwarding(); err != nil {
			eng.cleanupFailure = errors.Join(eng.cleanupFailure, err)
			return eng.cleanupFailure
		}
		if err := corecfg.LoadAll(&opts); err != nil {
			return err
		}

		installRuleProviderReuse()
		publishRuleProvidersLocked(nil, nil)
		constant.SetHomeDir(opts.HomeDir)
		constant.SetConfig(opts.ConfigPath)

		var nextInbound inboundSettings
		cfg, err := parseConfigWithInboundHash(opts.ConfigPath, &opts, &nextInbound)
		if err != nil {
			return err
		}
		eng.desiredInbound = nextInbound
		if err := route.ArkClashReCreateServer(&route.Config{
			Addr: cfg.Controller.ExternalController, Secret: cfg.Controller.Secret,
			RoutingMark: cfg.Controller.ExternalControllerRoutingMark,
			DohServer:   cfg.Controller.ExternalDohServer,
			Cors: route.Cors{AllowOrigins: cfg.Controller.Cors.AllowOrigins,
				AllowPrivateNetwork: cfg.Controller.Cors.AllowPrivateNetwork},
		}); err != nil {
			eng.desiredInbound = inboundSettings{}
			return err
		}
		executor.ApplyConfig(withoutBusinessInbounds(cfg), true)
		publishRuleProvidersLocked(cfg, nextInbound.ruleProviderKeys)

		eng.running = true
		eng.current = opts
		tx.deferUnlock(beginRuntime())
		manager, err := geo.NewManager(opts.HomeDir, eng.bootID, opts.Geo, eng.CommitGeoSwap)
		if err != nil {
			tx.deferUnlock(eng.diag.Stop())
			closeCoreListeners()
			executor.Shutdown()
			eng.cleanupFailure = errors.Join(eng.cleanupFailure, route.ArkClashCloseServer())
			tunnel.OnSuspend()
			tunnel.UpdateProxies(nil, nil)
			tunnel.UpdateRules(nil, nil, nil)
			publishRuleProvidersLocked(nil, nil)
			eng.running = false
			eng.current = corecfg.StartOptions{}
			eng.desiredInbound = inboundSettings{}
			eng.publishRuntimeLocked()
			return errors.Join(err, eng.cleanupFailure)
		}
		eng.geo.Store(manager)
		if opts.General.ControllerSecret != "" {
			if err := setPanelControllerLocked(opts.General.ControllerSecret); err != nil {
				log.Warnln("[ArkClash] external controller port unavailable")
			}
		}
		resetProxyIdentities()
		watchRuntimeRoutes(cfg)
		eng.providers.Reset(providers.Identity{
			BootID: eng.bootID, ConfigRevision: eng.configRevision, Profile: eng.current.Profile, HomeDir: eng.current.HomeDir,
		}, cfg)
		eng.publishRuntimeLocked()
		log.Infoln("[ArkClash] core started")
		return nil
	})
}

func parseConfig(path string, opts corecfg.StartOptions) (*config.Config, error) {
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
		if err := restoreSelections(cfg, opts); err != nil {
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

// reload 是热切换：解析 path，成功后换用新配置，profile 记为正在运行的配置。
// 只调 executor.ApplyConfig，不走 hub.ApplyConfig：后者的 applyRoute 每次都会关掉 controller
// 再重开，掐断发起热切换的请求和界面的 WebSocket（ADR-0010）。controller 的地址和 secret
// 由 applyOverrides 固定，不需要重建。改 start 的解析和应用流程时，这里要一起看。
func reload(path, profile string, expectedProfile *string) error {
	return eng.withState(func(tx *stateTx) error {
		if !eng.running {
			return errors.New("core is not running")
		}
		if expectedProfile != nil && eng.current.Profile != *expectedProfile {
			return errors.New("profile_changed")
		}
		if profile == "" {
			if path != "" || eng.tun != nil || eng.vpnCreated || businessListenersOpen() || eng.cleanupFailure != nil {
				return errors.New("empty profile requires a fully detached core")
			}
		} else if err := checkProfilePath(eng.current.HomeDir, path); err != nil {
			return err
		}
		next := eng.current
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

// 热切换只接受配置目录下的文件，见 entry/src/main/ets/shared/profiles/Store.ets。
func checkProfilePath(home, path string) error {
	return subfetch.CheckProfilePath(home, path)
}

func runningProfile() (string, bool) {
	v := eng.View()
	if v == nil || !v.Status.Running {
		return "", false
	}
	return v.Status.Profile, true
}

// setRuntimeOptions 立即修改出站模式和局域网代理，并记下来供之后的热切换使用。
func setRuntimeOptions(mode *string, allowLan *bool) error {
	return eng.withState(func(tx *stateTx) error {
		if !eng.running {
			return errors.New("core is not running")
		}
		if mode != nil {
			m, ok := tunnel.ModeMapping[strings.ToLower(*mode)]
			if !ok {
				return fmt.Errorf("unknown mode %q", *mode)
			}
			tunnel.SetMode(m)
			eng.current.Mode = *mode
		}
		if allowLan != nil {
			eng.desiredInbound.inbound.AllowLan = *allowLan
			listener.SetAllowLan(*allowLan)
			v := *allowLan
			eng.current.AllowLan = &v
		}
		eng.publishRuntimeLocked()
		return nil
	})
}

type attachIdentity struct {
	BootID         string
	Profile        string
	ConfigRevision uint64
}

type tunNetworkOptions struct {
	Stack                string
	IPv6                 bool
	DNSHijacking         bool
	MTU                  int
	CongestionController string
}

func attachTun(fd int, network tunNetworkOptions, expected attachIdentity) error {
	return eng.withLifecycle(func(tx *stateTx) error {
		if !eng.running {
			return errors.New("core is not running")
		}
		if expected.BootID != eng.bootID || expected.Profile != eng.current.Profile ||
			expected.ConfigRevision != eng.configRevision {
			return errors.New("stale_attach_identity")
		}
		if eng.current.Profile == "" || eng.current.ConfigPath == "" {
			return errors.New("no profile is loaded")
		}
		if fd <= 0 {
			return errors.New("invalid tun fd")
		}
		if eng.tun != nil {
			if eng.cleanupFailure != nil {
				return eng.cleanupFailure
			}
			return nil
		}
		if eng.cleanupFailure != nil {
			return eng.cleanupFailure
		}
		if err := startTun(fd, network); err != nil {
			// 平台构造器必须自行回滚未发布资源；已发布的 listener 仍由这里收尾。
			var cleanupErr error
			if eng.tun != nil {
				cleanupErr = stopTun()
			}
			eng.cleanupFailure = errors.Join(eng.cleanupFailure, cleanupErr)
			eng.publishRuntimeLocked()
			return errors.Join(err, eng.cleanupFailure)
		}
		if err := restoreBusinessInbounds(); err != nil {
			eng.cleanupFailure = errors.Join(eng.cleanupFailure, closeBusinessInbounds(), stopTun())
			eng.publishRuntimeLocked()
			return errors.Join(err, eng.cleanupFailure)
		}
		eng.publishRuntimeLocked()
		return nil
	})
}

func detachTun() error {
	return eng.withLifecycle(func(tx *stateTx) error {
		err := errors.Join(closeBusinessInbounds(), stopTun())
		eng.cleanupFailure = errors.Join(eng.cleanupFailure, err)
		// URLTest 直接拨指定节点，不登记到转发 tracker，断开不能取消其上下文。
		resolver.ResetConnection()
		eng.publishRuntimeLocked()
		return eng.cleanupFailure
	})
}

func closeCoreListeners() {
	eng.cleanupFailure = errors.Join(eng.cleanupFailure, closeBusinessInbounds())
	ntp.ReCreateNTPService("", 0, "", nil, false)
}

func stop() error {
	return eng.withLifecycle(func(tx *stateTx) error {
		_ = setPanelControllerLocked("")
		closeCoreListeners()
		if !eng.running && eng.tun == nil && !businessListenersOpen() {
			_ = updateVpnState("stopped", "stopped", eng.vpnCreated)
			return eng.cleanupFailure
		}
		tx.deferUnlock(eng.diag.Stop())
		manager := eng.geo.Swap(nil)
		if manager != nil {
			manager.Close()
			// worker 的热换提交可能需要核心锁，且下一次 start 不得越过本次 join。
			tx.deferUnlock(manager.Wait)
		}
		tx.deferUnlock(eng.providers.Close())
		resetProxyIdentities()
		stopRuntimeRoutes()
		cancelDelayTests()
		eng.cleanupFailure = errors.Join(eng.cleanupFailure, stopTun())
		resolver.ResetConnection()
		executor.Shutdown()
		eng.cleanupFailure = errors.Join(eng.cleanupFailure, route.ArkClashCloseServer())
		tunnel.OnSuspend()
		tunnel.UpdateProxies(nil, nil)
		tunnel.UpdateRules(nil, nil, nil)
		tunnel.UpdateListeners(nil)
		publishRuleProvidersLocked(nil, nil)
		eng.running = false
		eng.current = corecfg.StartOptions{}
		eng.desiredInbound = inboundSettings{}
		if err := updateVpnState("stopped", "stopped", eng.vpnCreated); err != nil {
			log.Errorln("[ArkClash] core stopped with pending VPN resources: %s", err)
		}
		return eng.cleanupFailure
	})
}
