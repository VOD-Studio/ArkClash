package main

import (
	"fmt"
	"io"
	"os"
	"sync/atomic"
	"time"

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
	Version               string `json:"version"`
	Mode                  string `json:"mode"`
}

func (start *statusResponse) subscriptionRouteCurrent() bool {
	now := runtimeSnapshot.Load()
	if now == nil || !now.Running || now.BootID != start.BootID || now.forwardRevision != start.forwardRevision {
		return false
	}
	return start.Forward != "running" || now.Revision == start.Revision
}

var runtimeSnapshot atomic.Pointer[statusResponse]
var runtimeBootID string
var runtimeStartedAt int64
var runtimeRevision uint64
var runtimeConfigRevision uint64
var runtimeIntent = "stopped"
var runtimeForward = "stopped"
var runtimeVpnCreated bool

func beginRuntime() func() {
	waitDiagnostics := stopDiagnosticsLocked()
	stopRuntimeRoutes()
	now := time.Now()
	runtimeBootID = fmt.Sprintf("%x-%x", os.Getpid(), now.UnixNano())
	runtimeStartedAt = 0
	runtimeRevision = 0
	runtimeConfigRevision = 1
	runtimeIntent = "stopped"
	runtimeForward = "stopped"
	runtimeVpnCreated = false
	selectionOperations = make(map[string]selectionOperation)
	selectionOrder = nil
	return waitDiagnostics
}

// 调用方持有 mu；平台资源事实与转发状态在同一个提交点发布。
func updateVpnState(intent, forward string, vpnCreated bool) error {
	if intent != "started" && intent != "stopped" {
		return fmt.Errorf("invalid_vpn_intent")
	}
	switch forward {
	case "stopped", "preparing", "running", "paused", "failed":
	default:
		return fmt.Errorf("invalid_vpn_forward")
	}
	runtimeIntent = intent
	runtimeForward = forward
	runtimeVpnCreated = vpnCreated
	publishRuntime()
	if runtimeForward != forward {
		return fmt.Errorf("vpn_resources_inconsistent")
	}
	return nil
}

func publishRuntime() {
	runtimeRevision++
	next := &statusResponse{
		Profile: current.Profile, PanelOpen: activePanel != nil, Running: running, Intent: runtimeIntent, Forward: runtimeForward, SessionMode: "tun",
		ListenersOpen: businessListenersOpen(),
		TunAttached:   tunListener != nil, VpnCreated: runtimeVpnCreated,
		BootID: runtimeBootID, Revision: runtimeRevision, Version: constant.Version, Mode: tunnel.Mode().String(),
		ConfigRevision: runtimeConfigRevision, ProfileExtension: current.Script.identity,
	}
	next.StandardRulesRevision = current.ProfileRules.Revision
	if next.Forward == "running" && (!running || next.Intent != "started" || !next.TunAttached || !next.VpnCreated) ||
		next.Forward == "stopped" && (next.TunAttached || next.VpnCreated || next.ListenersOpen) ||
		next.Forward == "preparing" && (!running || next.Intent != "started") || cleanupFailure != nil {
		next.Forward = "failed"
		runtimeForward = next.Forward
	}
	if next.Forward == "running" {
		if runtimeStartedAt == 0 {
			runtimeStartedAt = time.Now().UnixMilli()
		}
	} else {
		runtimeStartedAt = 0
	}
	next.StartedAt = runtimeStartedAt
	// 固定走 DIRECT 的请求不受自动选组变化影响；转发状态或配置切换仍使旧请求失效。
	next.forwardRevision = next.Revision
	if prev := runtimeSnapshot.Load(); prev != nil && prev.BootID == next.BootID &&
		prev.ConfigRevision == next.ConfigRevision && prev.Forward == next.Forward {
		next.forwardRevision = prev.forwardRevision
	}
	runtimeSnapshot.Store(next)
	emit(struct {
		Type   string          `json:"type"`
		Status *statusResponse `json:"status"`
	}{Type: "runtime", Status: next})
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

var runtimeRoutes atomic.Pointer[runtimeRouteWatch]

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
		bootID: runtimeBootID, configRevision: runtimeConfigRevision,
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
	runtimeRoutes.Store(watch)
	watch.subscriptions = []io.Closer{
		outboundgroup.RouteChangeCallback().Register(func(group constant.ProxyAdapter) {
			if runtimeRoutes.Load() != watch {
				return
			}
			if _, ok := watch.groups[group]; !ok {
				return
			}
			watch.changes.Add(1)
			watch.notify()
		}),
		adapter.HealthCheckCallback().Register(func(proxy constant.Proxy) {
			if runtimeRoutes.Load() != watch {
				return
			}
			if _, ok := (*watch.members.Load())[proxy]; !ok {
				return
			}
			watch.refresh.Store(true)
			watch.notify()
		}),
		provider.ProxyUpdateCallback().Register(func(item P.ProxyProvider) {
			if runtimeRoutes.Load() != watch {
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
		mu.Lock()
		if runtimeRoutes.Load() != watch || !running || runtimeBootID != watch.bootID || runtimeConfigRevision != watch.configRevision {
			mu.Unlock()
			return
		}
		if watch.refresh.Swap(false) {
			watch.updateMembers()
			now := time.Now()
			for adapter := range watch.groups {
				pending[adapter] = now
			}
		}
		var next time.Duration
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
			publishRuntime()
		}
		mu.Unlock()
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
	watch := runtimeRoutes.Swap(nil)
	if watch == nil {
		return
	}
	close(watch.done)
	for _, subscription := range watch.subscriptions {
		_ = subscription.Close()
	}
}
