package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/VOD-Studio/ArkClash/core/internal/providers"
	"github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/component/process"
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

// VPN 进程传入启动设置；JSON 避免新增设置改变 C ABI，TUN 由独立操作附加。
type startOptions struct {
	HomeDir    string `json:"homeDir"`
	ConfigPath string `json:"configPath"`
	Controller string `json:"controller"`
	Secret     string `json:"secret"`
	// 以下由 VPN 进程从 runtime.json 和配置列表（entry/src/main/ets/shared/）读出后传入。
	Profile  string `json:"profile"`  // 正在运行的配置的编号
	Mode     string `json:"mode"`     // 'rule' | 'global' | 'direct'，空串 = 用配置里的值
	AllowLan *bool  `json:"allowLan"` // nil = 用配置里的值
	// Geo 设置只由原生启动流程从磁盘读取，不扩展 C ABI 或 ArkTS 参数。
	Geo             geoSettings         `json:"-"`
	General         generalSettings     `json:"-"`
	DNS             dnsOverrideSettings `json:"-"`
	AddedRules      addedRulesSettings  `json:"-"`
	RuleSets        ruleSetCatalog      `json:"-"`
	Script          profileScript       `json:"-"`
	ProfileRules    profileAddedRules   `json:"-"`
	StoreGeneration string              `json:"-"`
	CustomRules     bool                `json:"-"`
	ContentHash     string              `json:"-"`
}

var (
	mu        sync.Mutex
	lifecycle sync.Mutex
	running   bool
	// 本次启动的参数，热切换和 PATCH /arkclash/configs 会更新其中的配置路径、编号、模式和局域网代理。
	current startOptions
	// 正在运行的配置编号，nil = 没在运行。ArkTS 主线程会同步读它，不能等 mu（热切换可能要几秒）。
	runningID atomic.Pointer[string]
)

func start(opts startOptions) error {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	mu.Lock()
	var waitDiagnostics func()
	defer func() {
		mu.Unlock()
		if waitDiagnostics != nil {
			waitDiagnostics()
		}
	}()

	if running {
		return errors.New("core is already running")
	}
	if tunListener != nil || runtimeVpnCreated {
		return errors.New("previous VPN resources are not released")
	}
	if cleanupFailure != nil {
		return cleanupFailure
	}
	inbound.EnableArkClashListenerOwnership()
	if err := tunnel.ArkClashSuspendForwarding(); err != nil {
		cleanupFailure = errors.Join(cleanupFailure, err)
		return cleanupFailure
	}
	opts.StoreGeneration = portableGeneration(opts.HomeDir)
	settings, err := readGeoSettings(opts.HomeDir)
	if err != nil {
		return err
	}
	opts.Geo = settings
	opts.General, err = readGeneralSettings(opts.HomeDir)
	if err != nil {
		return err
	}
	opts.DNS, err = readDNSOverrides(opts.HomeDir)
	if err != nil {
		return err
	}
	opts.AddedRules, err = readAddedRules(opts.HomeDir)
	if err != nil {
		return err
	}
	opts.RuleSets, err = readRuleSets(opts.HomeDir)
	if err != nil {
		return err
	}

	if err := loadProfileExtension(&opts); err != nil {
		return err
	}

	constant.SetHomeDir(opts.HomeDir)
	constant.SetConfig(opts.ConfigPath)

	var nextInbound inboundSettings
	cfg, err := parseConfigWithInboundHash(opts.ConfigPath, &opts, &nextInbound)
	if err != nil {
		return err
	}
	desiredInbound = nextInbound
	if err := route.ArkClashReCreateServer(&route.Config{
		Addr: cfg.Controller.ExternalController, Secret: cfg.Controller.Secret,
		RoutingMark: cfg.Controller.ExternalControllerRoutingMark,
		DohServer:   cfg.Controller.ExternalDohServer,
		Cors: route.Cors{AllowOrigins: cfg.Controller.Cors.AllowOrigins,
			AllowPrivateNetwork: cfg.Controller.Cors.AllowPrivateNetwork},
	}); err != nil {
		return err
	}
	executor.ApplyConfig(withoutBusinessInbounds(cfg), true)

	running = true
	current = opts
	runningID.Store(&opts.Profile)
	waitDiagnostics = beginRuntime()
	ensureDiagnosticLogsLocked()
	manager, err := newGeoManager(opts.HomeDir, runtimeBootID, opts.Geo)
	if err != nil {
		waitDiagnostics = together(waitDiagnostics, stopDiagnosticsLocked())
		closeCoreListeners()
		executor.Shutdown()
		cleanupFailure = errors.Join(cleanupFailure, route.ArkClashCloseServer())
		tunnel.OnSuspend()
		tunnel.UpdateProxies(nil, nil)
		tunnel.UpdateRules(nil, nil, nil)
		running = false
		current = startOptions{}
		runningID.Store(nil)
		publishRuntime()
		return errors.Join(err, cleanupFailure)
	}
	activeGeo.Store(manager)
	if opts.General.ControllerSecret != "" {
		if err := setPanelControllerLocked(opts.General.ControllerSecret); err != nil {
			log.Warnln("[ArkClash] external controller port unavailable")
		}
	}
	resetProxyIdentities()
	watchRuntimeRoutes(cfg)
	runtimeProviders.Reset(providers.Identity{
		BootID: runtimeBootID, ConfigRevision: runtimeConfigRevision, Profile: current.Profile, HomeDir: current.HomeDir,
	}, cfg)
	publishRuntime()
	log.Infoln("[ArkClash] core started")
	return nil
}

var errCustomTunUnsupported = errors.New("custom TUN listeners are not supported")

func parseConfig(path string, opts startOptions) (*config.Config, error) {
	return parseConfigWithInbound(path, opts, nil)
}

func parseConfigWithInbound(path string, opts startOptions, settings *inboundSettings) (*config.Config, error) {
	return parseConfigWithInboundHash(path, &opts, settings)
}

func parseConfigWithInboundHash(path string, opts *startOptions, settings *inboundSettings) (*config.Config, error) {
	rawCfg, hash, err := buildRawConfigWithHash(context.Background(), path, *opts)
	if err != nil {
		return nil, err
	}
	opts.ContentHash = hash
	cfg, err := prepareRawConfig(rawCfg, *opts, settings)
	if err != nil && opts.Script.enabled() && !errors.Is(err, errDNSProxyServersRequired) &&
		!errors.Is(err, errAddedRulesMatchTarget) {
		return nil, errScriptConfig
	}
	return cfg, err
}

func buildRawConfig(ctx context.Context, path string, opts startOptions) (*config.RawConfig, error) {
	rawCfg, _, err := buildRawConfigWithHash(ctx, path, opts)
	return rawCfg, err
}

func buildRawConfigWithHash(ctx context.Context, path string, opts startOptions) (*config.RawConfig, string, error) {
	if path == "" {
		if opts.Profile != "" {
			return nil, "", errors.New("selected profile requires a configuration path")
		}
		return config.DefaultRawConfig(), "", nil
	}
	buf, err := os.ReadFile(path)
	if err != nil {
		return nil, "", err
	}
	if len(buf) == 0 {
		return nil, "", errors.New("selected configuration is empty")
	}
	sum := sha256.Sum256(buf)
	hash := hex.EncodeToString(sum[:])
	if opts.Script.enabled() {
		rawCfg, err := scriptRawConfig(ctx, buf, opts.Script)
		return rawCfg, hash, err
	}
	rawCfg, err := config.UnmarshalRawConfig(buf)
	return rawCfg, hash, err
}

// composeRawConfig 组装实际交给 mihomo 的原始配置；运行加载与运行时预览共用同一套规则。
func composeRawConfig(rawCfg *config.RawConfig, opts startOptions) error {
	if opts.Profile != "" && !opts.CustomRules {
		rules := opts.AddedRules.effective(opts.ProfileRules)
		if err := prependAddedRules(rawCfg, rules, opts.ProfileRules.MatchTarget, opts.ProfileRules.ExitTargets); err != nil {
			return err
		}
		if err := opts.RuleSets.attach(rawCfg, opts.HomeDir, rules); err != nil {
			return err
		}
	}
	applyOverrides(rawCfg, opts)
	if opts.Profile != "" && opts.DNS.Entries.missingProxyServers(&rawCfg.DNS) {
		return errDNSProxyServersRequired
	}
	// 自定义 TUN 不经过平台 fd 所有权，不能让订阅绕过唯一的系统 VPN。
	for _, mapping := range rawCfg.Listeners {
		if kind, _ := mapping["type"].(string); kind == "tun" {
			return errCustomTunUnsupported
		}
	}
	return nil
}

func prepareRawConfig(rawCfg *config.RawConfig, opts startOptions, settings *inboundSettings) (*config.Config, error) {
	var baseline generalBaseline
	if settings != nil {
		baseline = captureRawGeneralBaseline(rawCfg, opts)
	}
	if err := composeRawConfig(rawCfg, opts); err != nil {
		return nil, err
	}
	if settings != nil {
		baseline.dnsRespectRules = rawCfg.DNS.RespectRules
		baseline.dnsHasFakeIPRange6 = rawCfg.DNS.FakeIPRange6 != ""
	}
	// 配置解析可能初始化缺失的 Geo，来源必须先固定为页面设置。
	setGeoURLs(opts.Geo)
	mappings := rawCfg.Listeners
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
		baseline.finalizeDNS(cfg.DNS, opts.Profile != "" && opts.General.AppendSystemDNS)
		*settings = captureInbound(cfg, mappings)
		settings.baseline = baseline
	}
	return cfg, nil
}

// reload 是热切换：解析 path，成功后换用新配置，profile 记为正在运行的配置。
// 只调 executor.ApplyConfig，不走 hub.ApplyConfig：后者的 applyRoute 每次都会关掉 controller
// 再重开，掐断发起热切换的请求和界面的 WebSocket（ADR-0010）。controller 的地址和 secret
// 由 applyOverrides 固定，不需要重建。改 start 的解析和应用流程时，这里要一起看。
func reload(path, profile string, expectedProfile *string) error {
	mu.Lock()
	var waitDiagnostics func()
	defer func() {
		mu.Unlock()
		if waitDiagnostics != nil {
			waitDiagnostics()
		}
	}()

	if !running {
		return errors.New("core is not running")
	}
	if expectedProfile != nil && current.Profile != *expectedProfile {
		return errors.New("profile_changed")
	}
	if profile == "" {
		if path != "" || tunListener != nil || runtimeVpnCreated || businessListenersOpen() || cleanupFailure != nil {
			return errors.New("empty profile requires a fully detached core")
		}
	} else if err := checkProfilePath(current.HomeDir, path); err != nil {
		return err
	}
	next := current
	next.Profile = profile
	next.ConfigPath = path
	if err := loadProfileExtension(&next); err != nil {
		return err
	}
	var nextInbound inboundSettings
	cfg, err := parseConfigWithInboundHash(path, &next, &nextInbound)
	if err != nil {
		return err
	}
	waitDiagnostics, err = applyReloadLocked(next, cfg, nextInbound)
	return err
}

func applyReloadLocked(next startOptions, cfg *config.Config, nextInbound inboundSettings) (func(), error) {
	return reloadPreparedLocked(next, cfg, nextInbound, false)
}

func reloadPreparedLocked(next startOptions, cfg *config.Config, nextInbound inboundSettings, canRestore bool) (func(), error) {
	cancelDelayTests()
	runtimeProviders.Invalidate()
	attached := tunListener != nil
	// 始终先屏蔽，避免 executor 接管平台 TUN，也避免失败时暴露部分入口。
	if err := closeBusinessInbounds(); err != nil {
		cleanupFailure = errors.Join(cleanupFailure, err, stopTun())
		resolver.ResetConnection()
		publishRuntime()
		return nil, cleanupFailure
	}
	waitDiagnostics := reloadDiagnosticsLocked()
	constant.SetConfig(next.ConfigPath)
	executor.ApplyConfig(withoutBusinessInbounds(cfg), true)
	desiredInbound = nextInbound
	current = next
	profile := next.Profile
	runningID.Store(&profile)
	runtimeConfigRevision++
	ensureDiagnosticCaptureCollectorsLocked()
	resetProxyIdentities()
	watchRuntimeRoutes(cfg)
	runtimeProviders.Reset(providers.Identity{
		BootID: runtimeBootID, ConfigRevision: runtimeConfigRevision, Profile: current.Profile, HomeDir: current.HomeDir,
	}, cfg)
	log.Infoln("[ArkClash] reloaded profile %s", next.Profile)
	var inboundErr error
	if attached {
		inboundErr = restoreBusinessInbounds()
		if inboundErr != nil && canRestore {
			return waitDiagnostics, inboundErr
		}
		if inboundErr != nil {
			cleanupFailure = errors.Join(cleanupFailure, closeBusinessInbounds(), stopTun())
		}
	}
	publishRuntime()
	emit(reloadedEvent{Type: "reloaded", Profile: next.Profile})
	return waitDiagnostics, errors.Join(inboundErr, cleanupFailure)
}

// 推给界面的「热切换完成」事件，格式和 entry/src/main/ets/client/ 里的解析一致。
type reloadedEvent struct {
	Type    string `json:"type"`
	Profile string `json:"profile"`
}

// 热切换只接受配置目录下的文件，见 entry/src/main/ets/shared/profiles/Store.ets。
func checkProfilePath(home, path string) error {
	if home == "" {
		return errors.New("invalid_profile_path")
	}
	dir := filepath.Dir(filepath.Clean(path))
	if dir != filepath.Join(home, "profiles") && dir != filepath.Join(home, "profile-work") {
		return errors.New("invalid_profile_path")
	}
	return nil
}

func runningProfile() (string, bool) {
	p := runningID.Load()
	if p == nil {
		return "", false
	}
	return *p, true
}

// setRuntimeOptions 立即修改出站模式和局域网代理，并记下来供之后的热切换使用。
func setRuntimeOptions(mode *string, allowLan *bool) error {
	mu.Lock()
	defer mu.Unlock()

	if !running {
		return errors.New("core is not running")
	}
	if mode != nil {
		m, ok := tunnel.ModeMapping[strings.ToLower(*mode)]
		if !ok {
			return fmt.Errorf("unknown mode %q", *mode)
		}
		tunnel.SetMode(m)
		current.Mode = *mode
	}
	if allowLan != nil {
		desiredInbound.inbound.AllowLan = *allowLan
		listener.SetAllowLan(*allowLan)
		v := *allowLan
		current.AllowLan = &v
	}
	publishRuntime()
	return nil
}

// applyOverrides forces the settings ArkClash owns, whatever the profile says.
func applyOverrides(rawCfg *config.RawConfig, opts startOptions) {
	opts.General.apply(rawCfg)
	// The TUN is created by VpnExtensionAbility and handed over as an fd, so the
	// profile must not try to create its own.
	rawCfg.Tun.Enable = false
	rawCfg.Tun.AutoRoute = false
	rawCfg.Tun.AutoRedirect = false
	rawCfg.Tun.AutoDetectInterface = false
	rawCfg.IPTables.Enable = false

	// 节点选择只从每配置文件恢复，避免 mihomo 全局同名组缓存覆盖它。
	rawCfg.Profile.StoreSelected = false
	// 只有资源管理器可以调度更新，订阅不能覆盖来源或启动第二个更新器。
	rawCfg.GeoXUrl = config.RawGeoXUrl{
		Mmdb: opts.Geo.URLs.MMDB, ASN: opts.Geo.URLs.ASN,
		GeoIp: opts.Geo.URLs.GeoIP, GeoSite: opts.Geo.URLs.GeoSite,
	}
	rawCfg.GeoAutoUpdate = false
	rawCfg.GeoUpdateInterval = opts.Geo.IntervalHours

	// The UI process drives the core over this controller only.
	rawCfg.ExternalController = opts.Controller
	rawCfg.Secret = opts.Secret
	rawCfg.ExternalControllerTLS = ""
	rawCfg.ExternalControllerUnix = ""
	rawCfg.ExternalControllerPipe = ""
	rawCfg.ExternalUI = ""

	// Process lookup scans /proc for every connection and cannot map to apps on
	// HarmonyOS anyway; it only costs battery.
	rawCfg.FindProcessMode = process.FindProcessOff

	// DNS from the TUN is hijacked into mihomo, so the resolver has to be on.
	if !rawCfg.DNS.Enable {
		rawCfg.DNS.Enable = true
		rawCfg.DNS.EnhancedMode = constant.DNSFakeIP
	}
	if opts.Profile != "" {
		opts.DNS.Entries.apply(&rawCfg.DNS)
		if opts.General.AppendSystemDNS {
			appendSystemDNS(&rawCfg.DNS)
		}
	}

	// 用户在界面上选过的出站模式和局域网代理优先于配置，热切换后不会被新配置改回去（ADR-0010）。
	if m, ok := tunnel.ModeMapping[strings.ToLower(opts.Mode)]; ok {
		rawCfg.Mode = m
	}
	if opts.AllowLan != nil {
		rawCfg.AllowLan = *opts.AllowLan
	}
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
	lifecycle.Lock()
	defer lifecycle.Unlock()
	mu.Lock()
	defer mu.Unlock()

	if !running {
		return errors.New("core is not running")
	}
	if expected.BootID != runtimeBootID || expected.Profile != current.Profile ||
		expected.ConfigRevision != runtimeConfigRevision {
		return errors.New("stale_attach_identity")
	}
	if current.Profile == "" || current.ConfigPath == "" {
		return errors.New("no profile is loaded")
	}
	if fd <= 0 {
		return errors.New("invalid tun fd")
	}
	if tunListener != nil {
		if cleanupFailure != nil {
			return cleanupFailure
		}
		return nil
	}
	if cleanupFailure != nil {
		return cleanupFailure
	}
	if err := startTun(fd, network); err != nil {
		// 平台构造器必须自行回滚未发布资源；已发布的 listener 仍由这里收尾。
		var cleanupErr error
		if tunListener != nil {
			cleanupErr = stopTun()
		}
		cleanupFailure = errors.Join(cleanupFailure, cleanupErr)
		publishRuntime()
		return errors.Join(err, cleanupFailure)
	}
	if err := restoreBusinessInbounds(); err != nil {
		cleanupFailure = errors.Join(cleanupFailure, closeBusinessInbounds(), stopTun())
		publishRuntime()
		return errors.Join(err, cleanupFailure)
	}
	publishRuntime()
	return nil
}

func detachTun() error {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	mu.Lock()
	defer mu.Unlock()

	err := errors.Join(closeBusinessInbounds(), stopTun())
	cleanupFailure = errors.Join(cleanupFailure, err)
	// URLTest 直接拨指定节点，不登记到转发 tracker，断开不能取消其上下文。
	resolver.ResetConnection()
	publishRuntime()
	return cleanupFailure
}

func closeCoreListeners() {
	cleanupFailure = errors.Join(cleanupFailure, closeBusinessInbounds())
	ntp.ReCreateNTPService("", 0, "", nil, false)
}

func stop() error {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	mu.Lock()
	_ = setPanelControllerLocked("")
	closeCoreListeners()
	if !running && tunListener == nil && !businessListenersOpen() {
		_ = updateVpnState("stopped", "stopped", runtimeVpnCreated)
		mu.Unlock()
		return cleanupFailure
	}
	waitDiagnostics := stopDiagnosticsLocked()
	manager := activeGeo.Swap(nil)
	if manager != nil {
		manager.closeLocked()
	}
	waitProviders := runtimeProviders.Close()
	resetProxyIdentities()
	stopRuntimeRoutes()
	cancelDelayTests()
	cleanupFailure = errors.Join(cleanupFailure, stopTun())
	resolver.ResetConnection()
	executor.Shutdown()
	cleanupFailure = errors.Join(cleanupFailure, route.ArkClashCloseServer())
	tunnel.OnSuspend()
	tunnel.UpdateProxies(nil, nil)
	tunnel.UpdateRules(nil, nil, nil)
	tunnel.UpdateListeners(nil)
	running = false
	current = startOptions{}
	runningID.Store(nil)
	desiredInbound = inboundSettings{}
	if err := updateVpnState("stopped", "stopped", runtimeVpnCreated); err != nil {
		log.Errorln("[ArkClash] core stopped with pending VPN resources: %s", err)
	}
	mu.Unlock()
	waitDiagnostics()
	// worker 的取消清理可能需要核心锁，且下一次 start 不得越过本次 join。
	if manager != nil {
		manager.wait()
	}
	waitProviders()
	return cleanupFailure
}
