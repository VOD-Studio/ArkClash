package engine

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/VOD-Studio/ArkClash/core/internal/backup"
	corecfg "github.com/VOD-Studio/ArkClash/core/internal/config"
	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/component/auth"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/geodata"
	mihomoHttp "github.com/metacubex/mihomo/component/http"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/component/trie"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/listener"
	authStore "github.com/metacubex/mihomo/listener/auth"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
)

func (e *Engine) profileSettingsCurrentLocked(bootID, expected, previous, next string) bool {
	return e.running && bootID != "" && bootID == e.bootID && expected == previous && next != expected
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
		if e.tun != nil && !e.dnsListenerAvailableLocked(nextInbound.dnsListen, nextInbound.dnsMark) {
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

func (e *Engine) dnsListenerAvailableLocked(address string, mark int) bool {
	if address == "" || address == e.desiredInbound.dnsListen {
		return true
	}
	lc := inbound.NewListenConfig()
	lc.SetRouteMark(mark)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	tcp, err := lc.Listen(ctx, "tcp", address)
	if err != nil {
		return false
	}
	defer tcp.Close()
	udp, err := lc.ListenPacket(ctx, "udp", address)
	if err != nil {
		return false
	}
	return udp.Close() == nil
}

func (e *Engine) UpdateDNSOverrides(request corecfg.DNSOverrideRequest) error {
	return e.withState(func(tx *stateTx) error {
		if !e.profileSettingsCurrentLocked(request.BootID, request.ExpectedRevision, e.current.DNS.Revision, request.Settings.Revision) {
			return corecfg.ErrDNSConflict
		}
		if err := request.Settings.Validate(); err != nil {
			return err
		}
		next := e.current
		next.DNS = request.Settings
		err := tx.CommitSettingsFile(next, corecfg.DNSOverridesPath(next.HomeDir), next.DNS)
		switch err {
		case nil:
			return nil
		case corecfg.ErrSettingsInvalid:
			return corecfg.ErrDNSInvalid
		case corecfg.ErrSettingsIO:
			return corecfg.ErrDNSIO
		case corecfg.ErrSettingsListen:
			return corecfg.ErrDNSListen
		case corecfg.ErrDNSProxyServersRequired:
			return corecfg.ErrDNSProxyServersRequired
		default:
			return corecfg.ErrDNSApply
		}
	})
}

func (e *Engine) UpdateAddedRules(request corecfg.SettingsRequest[corecfg.AddedRulesSettings]) error {
	return e.withState(func(tx *stateTx) error {
		if !e.profileSettingsCurrentLocked(request.BootID, request.ExpectedRevision, e.current.AddedRules.Revision, request.Settings.Revision) {
			return corecfg.ErrSettingsConflict
		}
		if err := request.Settings.Validate(); err != nil {
			return err
		}
		next := e.current
		next.AddedRules = request.Settings
		if next.AddedRules.Profiles == nil {
			next.AddedRules.Profiles = slices.Clone(e.current.AddedRules.Profiles)
		}
		if len(next.AddedRules.Profiles) > 0 {
			types, err := corecfg.ReadProfileTypes(next.HomeDir)
			if err != nil {
				return err
			}
			if types != nil {
				for _, entry := range next.AddedRules.Profiles {
					kind, exists := types[entry.Profile]
					if (!exists || kind == "custom") &&
						entry.Revision != e.current.AddedRules.ForProfile(entry.Profile).Revision {
						return corecfg.ErrSettingsConflict
					}
				}
				next.AddedRules.Profiles = slices.DeleteFunc(next.AddedRules.Profiles, func(entry corecfg.ProfileAddedRules) bool {
					kind, exists := types[entry.Profile]
					return !exists || kind == "custom"
				})
			}
		}
		globalIDs := make(map[string]bool, len(next.AddedRules.Rules))
		for _, rule := range next.AddedRules.Rules {
			globalIDs[rule.ID] = true
		}
		for i := range next.AddedRules.Profiles {
			entry := &next.AddedRules.Profiles[i]
			entry.Disabled = slices.DeleteFunc(slices.Clone(entry.Disabled), func(id string) bool { return !globalIDs[id] })
			prior := e.current.AddedRules.ForProfile(entry.Profile)
			if entry.Revision == prior.Revision &&
				(!slices.Equal(entry.Rules, prior.Rules) || entry.MatchTarget != prior.MatchTarget ||
					!slices.Equal(entry.ExitTargets, prior.ExitTargets) ||
					!slices.Equal(entry.Disabled, slices.DeleteFunc(slices.Clone(prior.Disabled), func(id string) bool {
						return !globalIDs[id]
					}))) {
				return corecfg.ErrSettingsConflict
			}
			if err := corecfg.ValidateAddedRuleContent(entry.Rules, prior.Rules, next.RuleSets); err != nil {
				return err
			}
		}
		if err := corecfg.ValidateAddedRuleContent(next.AddedRules.Rules, e.current.AddedRules.Rules, next.RuleSets); err != nil {
			return err
		}
		next.ProfileRules.Disabled = slices.DeleteFunc(slices.Clone(e.current.ProfileRules.Disabled), func(id string) bool {
			return !globalIDs[id]
		})
		if next.Profile == "" || next.CustomRules ||
			slices.Equal(e.current.AddedRules.Effective(e.current.ProfileRules), next.AddedRules.Effective(next.ProfileRules)) {
			path := corecfg.AddedRulesPath(next.HomeDir)
			staged, err := corecfg.StageSettings(path, next.AddedRules)
			if err != nil {
				return err
			}
			defer os.Remove(staged)
			if err := os.Rename(staged, path); err != nil {
				return corecfg.ErrSettingsIO
			}
			e.setCurrentLocked(next)
			return nil
		}
		return tx.CommitSettingsFile(next, corecfg.AddedRulesPath(next.HomeDir), next.AddedRules)
	})
}

func (e *Engine) ChangeRuleSet(ctx context.Context, request corecfg.RuleSetRequest) error {
	spec, ready := e.ConfigSpec()
	home, catalog, generation := spec.Options.HomeDir, spec.Options.RuleSets, spec.Options.StoreGeneration
	ok := ready && request.BootID != "" && request.BootID == spec.BootID &&
		request.ExpectedRevision == catalog.Revision && request.Revision != request.ExpectedRevision
	if !ok {
		return corecfg.ErrSettingsConflict
	}
	if !corecfg.ValidRuleSetRevision(request.Revision) {
		return corecfg.ErrRuleSetInput
	}
	index := catalog.Find(request.Item.ID)
	var previous corecfg.RuleSetItem
	if index >= 0 {
		previous = catalog.Items[index]
	}
	next := corecfg.RuleSetCatalog{Revision: request.Revision, Items: slices.Clone(catalog.Items)}
	contentChanged, committed := false, false
	switch request.Action {
	case "reorder":
		if len(request.Order) != len(catalog.Items) {
			return corecfg.ErrRuleSetInput
		}
		for n, id := range request.Order {
			i := catalog.Find(id)
			if i < 0 {
				return corecfg.ErrRuleSetInput
			}
			next.Items[n] = catalog.Items[i]
		}
	case "delete":
		if index < 0 {
			return corecfg.ErrSettingsConflict
		}
		next.Items = slices.Delete(next.Items, index, index+1)
	case "save", "sync":
		item := request.Item
		if request.Action == "sync" {
			item = previous
			if item.URL == "" {
				return corecfg.ErrRuleSetInput
			}
		}
		options := item
		if options.Format == "auto" {
			options.Format = "text"
		}
		if options.Behavior == "auto" {
			options.Behavior = "domain"
		}
		if !options.ValidOptions() || (index < 0 && len(catalog.Items) >= 100) {
			return corecfg.ErrRuleSetInput
		}
		for _, other := range catalog.Items {
			if other.ID != item.ID && (other.Name == item.Name || (item.URL != "" && other.URL == item.URL)) {
				return corecfg.ErrRuleSetInput
			}
		}
		item.Content, item.Count, item.UpdatedAt = previous.Content, previous.Count, previous.UpdatedAt
		if request.Action == "sync" || request.Candidate != "" || index < 0 || item.URL != previous.URL ||
			item.Behavior != previous.Behavior || item.Format != previous.Format {
			var err error
			item, contentChanged, err = corecfg.PrepareRuleSet(ctx, home, request, item, previous)
			if err != nil {
				return err
			}
		}
		if contentChanged {
			defer func() {
				if !committed {
					corecfg.RemoveRuleSetFiles(home, item)
				}
			}()
		}
		if index < 0 {
			next.Items = append(next.Items, item)
		} else {
			next.Items[index] = item
		}
	default:
		return corecfg.ErrRuleSetInput
	}
	if err := next.Validate(); err != nil {
		return err
	}
	if encoded, err := json.Marshal(next); err != nil || len(encoded) >= corecfg.ProfileSettingsLimit-1 {
		return corecfg.ErrRuleSetInput
	}
	unlock, err := lockPortableStorage(home)
	if err != nil {
		return corecfg.ErrSettingsConflict
	}
	defer unlock()
	if generation != backup.Generation(home) {
		return corecfg.ErrSettingsConflict
	}
	if err := e.commitRuleSets(ctx, request, next, contentChanged); err != nil {
		return err
	}
	committed = true
	if previous.Content != "" && (request.Action == "delete" || contentChanged) {
		corecfg.RemoveRuleSetFiles(home, previous)
	}
	return nil
}

func (e *Engine) commitRuleSets(ctx context.Context, request corecfg.RuleSetRequest, catalog corecfg.RuleSetCatalog, changed bool) error {
	return e.withState(func(tx *stateTx) error {
		if ctx.Err() != nil || !e.profileSettingsCurrentLocked(request.BootID, request.ExpectedRevision, e.current.RuleSets.Revision, request.Revision) {
			return corecfg.ErrSettingsConflict
		}
		references := func(rule corecfg.AddedRule) bool { return rule.Kind == "RULE-SET" && rule.Payload == request.Item.ID }
		active := e.current.Profile != "" && !e.current.CustomRules &&
			slices.ContainsFunc(e.current.AddedRules.Effective(e.current.ProfileRules), references)
		if request.Action == "delete" {
			if active || slices.ContainsFunc(e.current.AddedRules.Rules, references) {
				return corecfg.ErrRuleSetInUse
			}
			if len(e.current.AddedRules.Profiles) > 0 {
				types, err := corecfg.ReadProfileTypes(e.current.HomeDir)
				if err != nil {
					return err
				}
				for _, profile := range e.current.AddedRules.Profiles {
					kind, exists := types[profile.Profile]
					if (types == nil || exists && kind != "custom") && slices.ContainsFunc(profile.Rules, references) {
						return corecfg.ErrRuleSetInUse
					}
				}
			}
		}
		path := corecfg.RuleSetCatalogPath(e.current.HomeDir)
		if active && changed {
			next := e.current
			next.RuleSets = catalog
			return tx.CommitSettingsFile(next, path, catalog)
		}
		staged, err := corecfg.StageSettings(path, catalog)
		if err != nil {
			return err
		}
		defer os.Remove(staged)
		if err := os.Rename(staged, path); err != nil {
			return corecfg.ErrSettingsIO
		}
		next := e.current
		next.RuleSets = catalog
		e.setCurrentLocked(next)
		return nil
	})
}

func (e *Engine) ApplyProfileScript(ctx context.Context, request corecfg.ScriptApplyRequest) error {
	var (
		next     corecfg.StartOptions
		revision uint64
		conflict bool
	)
	_ = e.withState(func(tx *stateTx) error {
		if !e.running || e.bootID != request.BootID || e.current.Profile != request.Profile || e.current.CustomRules || e.cleanupFailure != nil {
			conflict = true
			return nil
		}
		next, revision = e.current, e.configRevision
		return nil
	})
	if conflict {
		return corecfg.ErrScriptConflict
	}

	selection, err := corecfg.ReadProfileScript(next.HomeDir, request.Profile)
	if err != nil {
		return err
	}
	if selection.Identity != request.Identity {
		return corecfg.ErrScriptConflict
	}
	standard, err := request.SelectedRules(next)
	if err != nil {
		return err
	}
	if next.Script.Identity == selection.Identity && next.ProfileRules.Revision == standard.Revision {
		return nil
	}
	next.Script = selection
	path := next.ConfigPath
	raw, hash, err := corecfg.BuildRawConfigWithHash(ctx, path, next)
	if errors.Is(err, os.ErrNotExist) {
		// 更新成功后，候选文件已原子改名成配置的固定路径。
		path = filepath.Join(next.HomeDir, "profiles", request.Profile+".yaml")
		raw, hash, err = corecfg.BuildRawConfigWithHash(ctx, path, next)
	}
	if err != nil {
		return corecfg.SanitizeScriptBuildError(err)
	}

	return e.withState(func(tx *stateTx) error {
		if ctx.Err() != nil || !e.running || e.bootID != request.BootID || revision != e.configRevision || e.cleanupFailure != nil {
			return corecfg.ErrScriptConflict
		}
		latest, err := corecfg.ReadProfileScript(next.HomeDir, request.Profile)
		if err != nil || latest.Identity != selection.Identity {
			return corecfg.ErrScriptConflict
		}
		standard, err = request.SelectedRules(e.current)
		if err != nil {
			return err
		}
		// 模式和局域网开关可以在脚本执行时变化，但不会增加配置版本。
		next = e.current
		next.ConfigPath, next.Script, next.ContentHash = path, selection, hash
		next.ProfileRules = standard
		var inbounds inboundSettings
		cfg, err := prepareRawConfig(raw, next, &inbounds)
		if err != nil {
			if errors.Is(err, corecfg.ErrAddedRulesMatchTarget) || errors.Is(err, corecfg.ErrDNSProxyServersRequired) {
				return err
			}
			if !selection.Enabled() {
				return corecfg.ErrSettingsInvalid
			}
			return corecfg.ErrScriptConfig
		}
		if e.tun != nil && !e.dnsListenerAvailableLocked(inbounds.dnsListen, inbounds.dnsMark) {
			return corecfg.ErrScriptConfig
		}
		if _, err := tx.CommitReload(reloadPlan{Next: next, Cfg: cfg, Inbound: inbounds}); err != nil {
			return corecfg.ErrScriptApply
		}
		return nil
	})
}

// BuildProfilePreview 在核心锁外生成完整 YAML，再持核锁复核 applied 标记，避免预览期间热切换返回旧结果。
func (e *Engine) BuildProfilePreview(ctx context.Context, profile string) (corecfg.PreviewResponse, int, error) {
	if !corecfg.ValidProfileID(profile) {
		return corecfg.PreviewResponse{}, http.StatusBadRequest, corecfg.ErrPreviewInvalidProfile
	}
	spec, ready := e.ConfigSpec()
	if !ready {
		return corecfg.PreviewResponse{}, http.StatusServiceUnavailable, corecfg.ErrPreviewCoreUnavailable
	}
	built, err := corecfg.BuildPreview(ctx, spec.Options, profile)
	if err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, corecfg.ErrPreviewNotFound) {
			status = http.StatusNotFound
		}
		return corecfg.PreviewResponse{}, status, err
	}

	var (
		applied        bool
		bootID         string
		configRevision uint64
		runningProfile string
	)
	if err := e.withState(func(tx *stateTx) error {
		if !e.running {
			return corecfg.ErrPreviewCoreUnavailable
		}
		applied = corecfg.PreviewMatchesCurrent(e.current, built.Options, built.Hash)
		bootID = e.bootID
		configRevision = e.configRevision
		runningProfile = e.current.Profile
		return nil
	}); err != nil {
		return corecfg.PreviewResponse{}, http.StatusServiceUnavailable, err
	}

	return corecfg.PreviewResponse{
		Profile:         profile,
		BootID:          bootID,
		ConfigRevision:  configRevision,
		ContentRevision: built.Meta.ContentRevision,
		ContentHash:     built.ShortHash(),
		Applied:         applied,
		RunningProfile:  runningProfile,
		CustomRules:     built.Options.CustomRules,
		ScriptIdentity:  built.Options.Script.Identity,
		YAML:            built.YAML,
	}, http.StatusOK, nil
}

type dnsRuntimeSnapshot struct {
	defaultResolver    resolver.Resolver
	defaultHostMapper  resolver.Enhancer
	defaultService     resolver.Service
	useSystemHosts     bool
	proxyHostResolver  resolver.Resolver
	directHostResolver resolver.Resolver
}

func captureDNSRuntime() dnsRuntimeSnapshot {
	return dnsRuntimeSnapshot{
		defaultResolver:    resolver.DefaultResolver,
		defaultHostMapper:  resolver.DefaultHostMapper,
		defaultService:     resolver.DefaultService,
		useSystemHosts:     resolver.UseSystemHosts,
		proxyHostResolver:  resolver.ProxyServerHostResolver,
		directHostResolver: resolver.DirectHostResolver,
	}
}

func (e *Engine) applyLiveDNSLocked(c *config.DNS, generalIPv6 bool, target inboundSettings) {
	if !c.Enable {
		resolver.DefaultResolver = nil
		resolver.DefaultHostMapper = nil
		resolver.DefaultService = nil
		resolver.ProxyServerHostResolver = nil
		resolver.DirectHostResolver = nil
		if e.tun != nil && target.dnsListen != "" {
			dns.ReCreateServer("", nil, nil)
		}
		return
	}

	ipv6 := c.IPv6 && generalIPv6
	r := dns.NewResolver(dns.Config{
		Main:                 c.NameServer,
		Fallback:             c.Fallback,
		IPv6:                 ipv6,
		IPv6Timeout:          c.IPv6Timeout,
		FallbackIPFilter:     c.FallbackIPFilter,
		FallbackDomainFilter: c.FallbackDomainFilter,
		FallbackLazyQuery:    c.FallbackLazyQuery,
		Default:              c.DefaultNameserver,
		Policy:               c.NameServerPolicy,
		ProxyServer:          c.ProxyServerNameserver,
		ProxyServerPolicy:    c.ProxyServerPolicy,
		DirectServer:         c.DirectNameServer,
		DirectFollowPolicy:   c.DirectFollowPolicy,
		CacheAlgorithm:       c.CacheAlgorithm,
		CacheMaxSize:         c.CacheMaxSize,
	})
	m := dns.NewEnhancer(dns.EnhancerConfig{
		IPv6:          ipv6,
		EnhancedMode:  c.EnhancedMode,
		FakeIPPool:    c.FakeIPPool,
		FakeIPPool6:   c.FakeIPPool6,
		FakeIPSkipper: c.FakeIPSkipper,
		FakeIPTTL:     c.FakeIPTTL,
		UseHosts:      c.UseHosts,
	})

	if old := resolver.DefaultHostMapper; old != nil {
		if enhancer, ok := old.(*dns.ResolverEnhancer); ok {
			m.PatchFrom(enhancer)
		}
	}

	s := dns.NewService(r, m)
	resolver.DefaultResolver = r
	resolver.DefaultHostMapper = m
	resolver.DefaultService = s
	resolver.UseSystemHosts = c.UseSystemHosts

	if r.ProxyResolver.Invalid() {
		resolver.ProxyServerHostResolver = r.ProxyResolver
	} else {
		resolver.ProxyServerHostResolver = r.Resolver
	}

	if r.DirectResolver.Invalid() {
		resolver.DirectHostResolver = r.DirectResolver
	} else {
		resolver.DirectHostResolver = r.Resolver
	}

	if e.tun != nil && target.dnsListen != "" {
		lc := inbound.NewListenConfig()
		lc.SetRouteMark(target.dnsMark)
		dns.ReCreateServer(target.dnsListen, lc, s)
	}
}

func (e *Engine) restoreDNSRuntimeLocked(snap dnsRuntimeSnapshot, target inboundSettings) {
	resolver.DefaultResolver = snap.defaultResolver
	resolver.DefaultHostMapper = snap.defaultHostMapper
	resolver.DefaultService = snap.defaultService
	resolver.UseSystemHosts = snap.useSystemHosts
	resolver.ProxyServerHostResolver = snap.proxyHostResolver
	resolver.DirectHostResolver = snap.directHostResolver
	if e.tun != nil && target.dnsListen != "" {
		lc := inbound.NewListenConfig()
		lc.SetRouteMark(target.dnsMark)
		dns.ReCreateServer(target.dnsListen, lc, snap.defaultService)
	}
}

func (e *Engine) UpdateGeneralSettings(request corecfg.SettingsRequest[corecfg.GeneralSettings]) error {
	return e.withState(func(tx *stateTx) error {
		old := e.current
		s := request.Settings
		if !e.profileSettingsCurrentLocked(request.BootID, request.ExpectedRevision, old.General.Revision, s.Revision) {
			return corecfg.ErrGeneralConflict
		}
		if err := s.Validate(); err != nil {
			return err
		}
		next := old
		next.General = s
		previousInbound := e.desiredInbound
		targetInbound := previousInbound
		baseline := previousInbound.baseline

		hostsChanged := !reflect.DeepEqual(old.General.Hosts, s.Hosts)
		uaChanged := old.General.UserAgent != s.UserAgent
		appendDNSChanged := old.General.AppendSystemDNS != s.AppendSystemDNS
		var oldOverrides, nextOverrides corecfg.GeneralCoreOverrides
		if old.General.CoreOverrides != nil {
			oldOverrides = *old.General.CoreOverrides
		}
		if s.CoreOverrides != nil {
			nextOverrides = *s.CoreOverrides
		}
		unifiedChanged := !corecfg.SameBoolPtr(oldOverrides.UnifiedDelay, nextOverrides.UnifiedDelay)
		tcpChanged := !corecfg.SameBoolPtr(oldOverrides.TCPConcurrent, nextOverrides.TCPConcurrent)
		ipv6Changed := !corecfg.SameBoolPtr(oldOverrides.IPv6, nextOverrides.IPv6)
		loaderChanged := !corecfg.SameStringPtr(oldOverrides.GeodataLoader, nextOverrides.GeodataLoader)
		liveGeneralChanged := hostsChanged || uaChanged || appendDNSChanged ||
			unifiedChanged || tcpChanged || ipv6Changed || loaderChanged

		rebuild := s.Ports == nil && old.General.Ports != nil ||
			s.Authentication == nil && old.General.Authentication != nil ||
			(liveGeneralChanged && !baseline.Ready())
		if !rebuild && baseline.Ready() && baseline.DNSConfig() != nil {
			nextIPv6 := baseline.EffectiveIPv6(s)
			// 开启 IPv6 且原配置因禁用 IPv6 跳过了 fake-ip-range6 初始化时，走完整重建以交由内核校验 IPv6 环境。
			if ipv6Changed && nextIPv6 && baseline.DNSHasFakeIPRange6() && !baseline.DNSConfig().FakeIPRange6.IsValid() {
				rebuild = true
			}
			if ipv6Changed && !nextIPv6 && baseline.DNSConfig().EnhancedMode == C.DNSFakeIP && !baseline.DNSConfig().FakeIPRange.IsValid() {
				rebuild = true
			}
			if (appendDNSChanged || ipv6Changed) && baseline.DNSConfig().Enable && len(baseline.DNSServers(next.Profile, s.AppendSystemDNS)) == 0 {
				rebuild = true
			}
		}

		var (
			cfg       *config.Config
			nextHosts *trie.DomainTrie[resolver.HostValue]
			nextDNS   *config.DNS
		)
		if rebuild {
			var err error
			cfg, err = parseProfileSettingsConfig(&next, &targetInbound)
			if err != nil {
				return corecfg.ErrGeneralApply
			}
		} else {
			if s.Ports != nil {
				p := s.Ports
				b := &targetInbound.inbound
				b.MixedPort, b.Port, b.SocksPort, b.RedirPort, b.TProxyPort = p.Mixed, p.HTTP, p.SOCKS, p.Redir, p.TProxy
			}
			if hostsChanged {
				var err error
				nextHosts, err = corecfg.BuildMergedHosts(baseline.RawHosts(), s.Hosts)
				if err != nil {
					return corecfg.ErrGeneralApply
				}
			}
			dnsChanged := (appendDNSChanged && next.Profile != "" && !baseline.DNSAlreadyHasSystem()) || ipv6Changed
			if dnsChanged && baseline.DNSConfig() != nil {
				var err error
				nextDNS, err = corecfg.BuildLiveDNSConfig(baseline, next.Profile, s.AppendSystemDNS, baseline.EffectiveIPv6(s))
				if err != nil {
					return corecfg.ErrGeneralApply
				}
			}
		}
		if err := e.preflightGeneralPortsLocked(targetInbound, s.ControllerSecret != ""); err != nil {
			return err
		}
		path := corecfg.GeneralSettingsPath(old.HomeDir)
		staged, err := corecfg.StageSettings(path, s)
		if err != nil {
			return corecfg.ErrGeneralIO
		}
		defer os.Remove(staged)
		if err := e.setPanelControllerLocked(s.ControllerSecret); err != nil {
			e.publishRuntimeLocked()
			return corecfg.ErrGeneralPanel
		}

		oldAuth := authStore.Default.Authenticator()
		oldUA := mihomoHttp.UA()
		oldUnified := adapter.UnifiedDelay.Load()
		oldTCP := dialer.GetTcpConcurrent()
		oldDisableIPv6 := resolver.DisableIPv6
		oldLoader := geodata.LoaderName()
		oldHosts := resolver.DefaultHosts
		oldDNS := captureDNSRuntime()
		appliedLive := false

		appliedReload := false
		if rebuild {
			appliedReload, err = tx.CommitReload(reloadPlan{
				Next:                 next,
				Cfg:                  cfg,
				Inbound:              targetInbound,
				AllowInboundRollback: true,
			})
		} else {
			err = e.applyGeneralListenersLocked(targetInbound, s.Authentication)
			if err == nil && liveGeneralChanged {
				appliedLive = true
				if uaChanged {
					mihomoHttp.SetUA(baseline.EffectiveUA(s))
				}
				if unifiedChanged {
					adapter.UnifiedDelay.Store(baseline.EffectiveUnifiedDelay(s))
				}
				if tcpChanged {
					dialer.SetTcpConcurrent(baseline.EffectiveTCPConcurrent(s))
				}
				if loaderChanged {
					geodata.SetLoader(baseline.EffectiveGeodataLoader(s))
				}
				if ipv6Changed {
					resolver.DisableIPv6 = !baseline.EffectiveIPv6(s)
				}
				if hostsChanged {
					resolver.DefaultHosts = resolver.NewHosts(nextHosts)
				}
				if nextDNS != nil {
					e.applyLiveDNSLocked(nextDNS, baseline.EffectiveIPv6(s), targetInbound)
				}
			}
		}
		if err == nil {
			if os.Rename(staged, path) == nil {
				if nextDNS != nil {
					if oldDNS.defaultResolver != nil {
						oldDNS.defaultResolver.ResetConnection()
					}
					resolver.ResetConnection()
				}
				e.current = next
				log.SetLevel(s.Level())
				if !rebuild {
					tx.deferUnlock(e.diag.SetCaptureLogs(s.CaptureLogs))
				}
				e.publishRuntimeLocked()
				return nil
			}
			err = corecfg.ErrGeneralIO
		} else {
			err = corecfg.ErrGeneralPort
		}

		if rebuild && appliedReload {
			_ = tx.RollbackReload(old, previousInbound)
		} else if !rebuild {
			if appliedLive {
				mihomoHttp.SetUA(oldUA)
				adapter.UnifiedDelay.Store(oldUnified)
				dialer.SetTcpConcurrent(oldTCP)
				geodata.SetLoader(oldLoader)
				resolver.DisableIPv6 = oldDisableIPv6
				resolver.DefaultHosts = oldHosts
				if nextDNS != nil {
					e.restoreDNSRuntimeLocked(oldDNS, previousInbound)
				}
			}
			authStore.Default.SetAuthenticator(oldAuth)
			inbound.SetSkipAuthPrefixes(previousInbound.inbound.SkipAuthPrefixes)
			if rollbackErr := e.applyGeneralListenersLocked(previousInbound, nil); rollbackErr != nil {
				e.cleanupFailure = errors.Join(e.cleanupFailure, closeBusinessInbounds(), e.stopTunLocked(), rollbackErr)
			}
		}
		if e.setPanelControllerLocked(old.General.ControllerSecret) != nil {
			err = corecfg.ErrGeneralApply
		}
		e.setCurrentLocked(old)
		log.SetLevel(old.General.Level())
		return err
	})
}

func portsFromInbound(b config.Inbound) corecfg.GeneralPorts {
	return corecfg.GeneralPorts{Mixed: b.MixedPort, HTTP: b.Port, SOCKS: b.SocksPort, Redir: b.RedirPort, TProxy: b.TProxyPort}
}

func (e *Engine) preflightGeneralPortsLocked(target inboundSettings, panel bool) error {
	b := target.inbound
	ports := portsFromInbound(b).Values()
	address := "127.0.0.1"
	if b.AllowLan && b.BindAddress == "*" {
		address = ""
	} else if b.AllowLan {
		address = strings.Trim(b.BindAddress, "[]")
	}
	active := listener.GetPorts()
	for i, port := range ports {
		if port == 0 {
			continue
		}
		if port == 19090 || panel && port == corecfg.PanelPort {
			return corecfg.ErrGeneralPort
		}
		if e.tun == nil || port == active.Port || port == active.SocksPort || port == active.RedirPort ||
			port == active.TProxyPort || port == active.MixedPort {
			continue
		}
		addr := net.JoinHostPort(address, strconv.Itoa(port))
		var lc net.ListenConfig
		socket, err := lc.Listen(context.Background(), "tcp", addr)
		if err != nil {
			return corecfg.ErrGeneralPort
		}
		_ = socket.Close()
		if i == 0 || i == 2 || i == 4 {
			packet, err := lc.ListenPacket(context.Background(), "udp", addr)
			if err != nil {
				return corecfg.ErrGeneralPort
			}
			_ = packet.Close()
		}
	}
	return nil
}

func (e *Engine) applyGeneralListenersLocked(target inboundSettings, a *corecfg.GeneralAuthentication) error {
	if a != nil {
		var users []auth.AuthUser
		if a.Enabled {
			users = []auth.AuthUser{{User: a.Username, Pass: a.Password}}
		}
		authStore.Default.SetAuthenticator(auth.NewAuthenticator(users))
		target.inbound.SkipAuthPrefixes = nil
		inbound.SetSkipAuthPrefixes(nil)
	}
	e.desiredInbound = target
	if e.tun == nil {
		return nil
	}
	old := listener.GetPorts()
	prior := corecfg.GeneralPorts{Mixed: old.MixedPort, HTTP: old.Port, SOCKS: old.SocksPort, Redir: old.RedirPort, TProxy: old.TProxyPort}.Values()
	next := portsFromInbound(target.inbound).Values()
	rebind := [...]func(int, C.Tunnel){
		listener.ReCreateMixed, listener.ReCreateHTTP, listener.ReCreateSocks, listener.ReCreateRedir, listener.ReCreateTProxy,
	}
	for i, bind := range rebind {
		if prior[i] != next[i] && prior[i] != 0 {
			bind(0, tunnel.Tunnel)
		}
	}
	for i, bind := range rebind {
		if prior[i] != next[i] && next[i] != 0 {
			bind(next[i], tunnel.Tunnel)
		}
	}
	active := listener.GetPorts()
	if (corecfg.GeneralPorts{Mixed: active.MixedPort, HTTP: active.Port, SOCKS: active.SocksPort, Redir: active.RedirPort, TProxy: active.TProxyPort}) != portsFromInbound(target.inbound) {
		return corecfg.ErrGeneralPort
	}
	return nil
}
