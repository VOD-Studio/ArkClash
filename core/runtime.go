package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sync/atomic"
	"time"

	"github.com/VOD-Studio/ArkClash/core/internal/ctrl"
	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/tunnel"
)

// 快照只在持有 mu 的提交点替换，controller 查询不等待配置解析或资源关闭。
type statusResponse struct {
	Profile               string `json:"profile"`
	PanelOpen             bool   `json:"panelOpen"`
	ProfileExtension      string `json:"profileExtension,omitempty"`
	StandardRulesRevision string `json:"standardRulesRevision,omitempty"`
	Running               bool   `json:"running"`
	Intent                string `json:"intent"`
	Forward               string `json:"forward"`
	SessionMode           string `json:"sessionMode"`
	ListenersOpen         bool   `json:"listenersOpen"`
	TunAttached           bool   `json:"tunAttached"`
	VpnCreated            bool   `json:"vpnCreated"`
	StartedAt             int64  `json:"startedAt"`
	BootID                string `json:"bootId"`
	Revision              uint64 `json:"revision"`
	ConfigRevision        uint64 `json:"configRevision"`
	forwardRevision       uint64
	homeDir               string
	Version               string `json:"version"`
	Mode                  string `json:"mode"`
}

func (start *statusResponse) subscriptionRouteCurrent() bool {
	now := eng.Status()
	if now == nil || !now.Running || now.BootID != start.BootID || now.forwardRevision != start.forwardRevision {
		return false
	}
	return start.Forward != "running" || now.Revision == start.Revision
}

func beginRuntime() func() {
	stopRuntimeRoutes()
	now := time.Now()
	eng.bootID = fmt.Sprintf("%x-%x", os.Getpid(), now.UnixNano())
	eng.startedAt = 0
	eng.revision = 0
	eng.configRevision = 1
	eng.intent = "stopped"
	eng.forward = "stopped"
	eng.vpnCreated = false
	eng.selections.ops = make(map[string]selectionOperation)
	eng.selections.order = nil
	return eng.diag.Start(eng.diagIdentityLocked())
}

// 供宿主（lib.go）更新平台 VPN 资源与转发状态；内部持核锁提交并发布快照。
func setVpnStateFromHost(intent, forward string, vpnCreated bool) error {
	return eng.withState(func(tx *stateTx) error {
		return updateVpnState(intent, forward, vpnCreated)
	})
}

// 供宿主（lib.go）无锁读取当前运行快照的 JSON 编码。
func runtimeStatusJSON() string {
	data, _ := json.Marshal(eng.Status())
	return string(data)
}

// 调用方持有 eng.mu；平台资源事实与转发状态在同一个提交点发布。
func updateVpnState(intent, forward string, vpnCreated bool) error {
	if intent != "started" && intent != "stopped" {
		return fmt.Errorf("invalid_vpn_intent")
	}
	switch forward {
	case "stopped", "preparing", "running", "paused", "failed":
	default:
		return fmt.Errorf("invalid_vpn_forward")
	}
	eng.intent = intent
	eng.forward = forward
	eng.vpnCreated = vpnCreated
	eng.publishRuntimeLocked()
	if eng.forward != forward {
		return fmt.Errorf("vpn_resources_inconsistent")
	}
	return nil
}

func publishRuntime() {
	eng.publishRuntimeLocked()
}

func (e *coreEngine) publishRuntimeLocked() {
	e.revision++
	next := statusResponse{
		Profile: e.current.Profile, PanelOpen: e.panel != nil, Running: e.running, Intent: e.intent, Forward: e.forward, SessionMode: "tun",
		ListenersOpen: businessListenersOpen(),
		TunAttached:   e.tun != nil, VpnCreated: e.vpnCreated,
		BootID: e.bootID, Revision: e.revision, Version: constant.Version, Mode: tunnel.Mode().String(),
		ConfigRevision: e.configRevision, ProfileExtension: e.current.Script.Identity,
		homeDir: e.current.HomeDir,
	}
	next.StandardRulesRevision = e.current.ProfileRules.Revision
	if next.Forward == "running" && (!e.running || next.Intent != "started" || !next.TunAttached || !next.VpnCreated) ||
		next.Forward == "stopped" && (next.TunAttached || next.VpnCreated || next.ListenersOpen) ||
		next.Forward == "preparing" && (!e.running || next.Intent != "started") || e.cleanupFailure != nil {
		next.Forward = "failed"
		e.forward = next.Forward
	}
	if next.Forward == "running" {
		if e.startedAt == 0 {
			e.startedAt = time.Now().UnixMilli()
		}
	} else {
		e.startedAt = 0
	}
	next.StartedAt = e.startedAt
	// 固定走 DIRECT 的请求不受自动选组变化影响；转发状态或配置切换仍使旧请求失效。
	next.forwardRevision = next.Revision
	if prev := e.Status(); prev != nil && prev.BootID == next.BootID &&
		prev.ConfigRevision == next.ConfigRevision && prev.Forward == next.Forward {
		next.forwardRevision = prev.forwardRevision
	}
	view := &runtimeView{
		Status:          next,
		HomeDir:         e.current.HomeDir,
		StoreGeneration: e.current.StoreGeneration,
		CaptureLogs:     e.current.General.CaptureLogs,
		DelayTimeout:    e.current.General.DelayTimeout,
	}
	e.view.Store(view)
	ctrl.Emit(struct {
		Type   string          `json:"type"`
		Status *statusResponse `json:"status"`
	}{Type: "runtime", Status: &view.Status})
}

type automaticRuntimeGroup interface {
	Now() string
	Proxies() []constant.Proxy
	Refresh(time.Time) time.Duration
}

type runtimeRouteWatch struct {
	bootID         string
	configRevision uint64
	groups         map[constant.ProxyAdapter]automaticRuntimeGroup
	providers      map[P.ProxyProvider]struct{}
	members        atomic.Pointer[map[constant.Proxy]struct{}]
	changes        atomic.Uint64
	refresh        atomic.Bool
	published      uint64
	wake           chan struct{}
	done           chan struct{}
	subscriptions  []io.Closer
}

func (watch *runtimeRouteWatch) notify() {
	select {
	case watch.wake <- struct{}{}:
	default:
	}
}

// 这些回调由 mihomo 的健康检查和真实选路触发，只入队，不反向取得核心 mu。
func watchRuntimeRoutes(cfg *config.Config) {
	stopRuntimeRoutes()
	watch := &runtimeRouteWatch{
		bootID: eng.bootID, configRevision: eng.configRevision,
		groups:    make(map[constant.ProxyAdapter]automaticRuntimeGroup),
		providers: make(map[P.ProxyProvider]struct{}),
		wake:      make(chan struct{}, 1), done: make(chan struct{}),
	}
	for _, proxy := range cfg.Proxies {
		if proxy.Type() != constant.URLTest && proxy.Type() != constant.Fallback {
			continue
		}
		group := proxy.Adapter().(automaticRuntimeGroup)
		group.Now()
		watch.groups[proxy.Adapter()] = group
	}
	for _, item := range cfg.Providers {
		if item.VehicleType() == P.HTTP || item.VehicleType() == P.File {
			watch.providers[item] = struct{}{}
		}
	}
	if len(watch.groups) == 0 && len(watch.providers) == 0 {
		return
	}
	watch.updateMembers()
	eng.routes.Store(watch)
	watch.subscriptions = []io.Closer{
		outboundgroup.RouteChangeCallback().Register(func(group constant.ProxyAdapter) {
			if eng.routes.Load() != watch {
				return
			}
			if _, ok := watch.groups[group]; !ok {
				return
			}
			watch.changes.Add(1)
			watch.notify()
		}),
		adapter.HealthCheckCallback().Register(func(proxy constant.Proxy) {
			if eng.routes.Load() != watch {
				return
			}
			if _, ok := (*watch.members.Load())[proxy]; !ok {
				return
			}
			watch.refresh.Store(true)
			watch.notify()
		}),
		provider.ProxyUpdateCallback().Register(func(item P.ProxyProvider) {
			if eng.routes.Load() != watch {
				return
			}
			if _, ok := watch.providers[item]; !ok {
				return
			}
			watch.changes.Add(1)
			watch.refresh.Store(true)
			watch.notify()
		}),
	}
	go watch.run()
}

func (watch *runtimeRouteWatch) updateMembers() {
	members := make(map[constant.Proxy]struct{})
	for _, group := range watch.groups {
		for _, proxy := range group.Proxies() {
			members[proxy] = struct{}{}
		}
	}
	watch.members.Store(&members)
}

func (watch *runtimeRouteWatch) run() {
	pending := make(map[constant.ProxyAdapter]time.Time)
	var timer *time.Timer
	var expiry <-chan time.Time
	defer func() {
		if timer != nil {
			timer.Stop()
		}
	}()
	for {
		select {
		case <-watch.done:
			return
		case <-watch.wake:
		case <-expiry:
		}
		var (
			stale bool
			next  time.Duration
		)
		_ = eng.withState(func(tx *stateTx) error {
			if eng.routes.Load() != watch || !eng.running || eng.bootID != watch.bootID || eng.configRevision != watch.configRevision {
				stale = true
				return nil
			}
			if watch.refresh.Swap(false) {
				watch.updateMembers()
				now := time.Now()
				for adapter := range watch.groups {
					pending[adapter] = now
				}
			}
			for adapter, since := range pending {
				wait := watch.groups[adapter].Refresh(since)
				if wait <= 0 {
					delete(pending, adapter)
				} else if next == 0 || wait < next {
					next = wait
				}
			}
			if changes := watch.changes.Load(); changes != watch.published {
				watch.published = changes
				eng.publishRuntimeLocked()
			}
			return nil
		})
		if stale {
			return
		}
		// 每个健康批次只等真实缓存到期；没有待处理变化时不保留周期任务。
		expiry = nil
		if timer != nil && !timer.Stop() {
			select {
			case <-timer.C:
			default:
			}
		}
		if next > 0 {
			if timer == nil {
				timer = time.NewTimer(next)
			} else {
				timer.Reset(next)
			}
			expiry = timer.C
		}
	}
}

func stopRuntimeRoutes() {
	watch := eng.routes.Swap(nil)
	if watch == nil {
		return
	}
	close(watch.done)
	for _, subscription := range watch.subscriptions {
		_ = subscription.Close()
	}
}
