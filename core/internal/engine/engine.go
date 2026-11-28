// Package engine 承载 ArkClash 内核单一状态机（Engine）、核心锁原语、热切换事务与运行态资源管理。
// 全内核唯一持核心锁（lifecycle / mu）的包，所有跨子系统锁序严格向下。
package engine

import (
	"context"
	"errors"
	"net"
	"strconv"
	"sync"
	"sync/atomic"

	corecfg "github.com/VOD-Studio/ArkClash/core/internal/config"
	"github.com/VOD-Studio/ArkClash/core/internal/ctrl"
	"github.com/VOD-Studio/ArkClash/core/internal/diagnostics"
	"github.com/VOD-Studio/ArkClash/core/internal/geo"
	"github.com/VOD-Studio/ArkClash/core/internal/providers"
	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/executor"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
)

// RuntimeView 是 Tier 1 无锁只读热路径快照，在每次持有 e.mu 的提交点原子整体替换。
// 调用方不得修改返回快照中的任何字段。
type RuntimeView struct {
	Status          StatusResponse
	HomeDir         string
	StoreGeneration string
	CaptureLogs     bool
	DelayTimeout    int
}

// ConfigSpec 是 Tier 2 锁外慢路径（配置预览、QuickJS 脚本执行、规则集预检）使用的配置规格浅拷贝。
// 不变量：StartOptions 及其嵌套结构中的切片和 map（如 Hosts、Rules、Profiles、Items 等）
// 只能整体替换，禁止原地修改，保证锁外读取安全。
type ConfigSpec struct {
	BootID         string
	ConfigRevision uint64
	Options        corecfg.StartOptions
}

type postUnlockTasks struct {
	fns []func()
}

func (p *postUnlockTasks) add(fn func()) {
	if fn != nil {
		p.fns = append(p.fns, fn)
	}
}

func (p *postUnlockTasks) run() {
	for _, fn := range p.fns {
		fn()
	}
}

type stateTx struct {
	e          *Engine
	postUnlock postUnlockTasks
}

func (tx *stateTx) deferUnlock(fn func()) {
	tx.postUnlock.add(fn)
}

type proxyIdentityTable struct {
	boot     string
	revision uint64
	sequence uint64
	byProxy  map[C.Proxy]string
	byID     map[string]C.Proxy
}

type selectionDedupLog struct {
	ops   map[string]selectionOperation
	order []string
}

type activeDelayRegistry struct {
	active map[*delayToken]context.CancelFunc
}

type Engine struct {
	// 顶层生命周期串行锁：串行 Start / AttachTun / DetachTun / Stop，
	// 保证 Stop 解锁 e.mu 后的异步 worker join 全部完成后才允许下一次 Start。
	lifecycle sync.Mutex

	// 核心提交锁。严格单向锁序：
	// lifecycle -> e.mu -> {providers.mu, geo.mu, diag.mu -> collector.mu -> statsMu}
	mu sync.Mutex

	// 1. 生命周期与运行身份
	running        bool
	current        corecfg.StartOptions
	bootID         string
	startedAt      int64
	revision       uint64
	configRevision uint64
	intent         string
	forward        string
	vpnCreated     bool

	// 2. 平台与入口资源
	desiredInbound    inboundSettings
	cleanupFailure    error
	tun               TunHandle
	tunCloseErr       error
	tunCloseAttempted bool
	tunFactory        func(LC.Tun) (TunHandle, error)
	panelAddr         string
	panel             *panelController
	// panelOpSeq 永不单独复位，避免新操作号命中尚未清空的 selections 去重表。
	panelOpSeq atomic.Uint64

	// 3. 绑定当前配置代次的辅助状态
	proxies    proxyIdentityTable
	selections selectionDedupLog
	delays     activeDelayRegistry

	// 4. 无锁只读快照
	view atomic.Pointer[RuntimeView]
	// 最近一次生效配置里的 rule provider，在 e.mu 下整份发布，mihomo 解析钩子在锁外只读（ADR-0043）。
	ruleProviders atomic.Pointer[ruleProviderGeneration]

	// 5. 下游独立子系统、并发槽与路线监听
	providers       *providers.Hub
	diag            *diagnostics.Hub
	geo             atomic.Pointer[geo.Manager]
	routes          atomic.Pointer[runtimeRouteWatch]
	ruleSetMutation chan struct{}
	delaySlots      chan struct{}
	backupDAVBusy   atomic.Bool

	// 仅宿主测试挂载，用于在 withState 解锁前校验 view 与核心状态一致。
	unlockCheck func(*Engine)
}

func defaultTunFactory(options LC.Tun) (TunHandle, error) {
	l, err := sing_tun.New(options, tunnel.Tunnel)
	if err != nil {
		// 显式返回无类型 nil，避免 (*sing_tun.Listener)(nil) 落入 tun != nil 判断。
		return nil, err
	}
	return l, nil
}

func New() *Engine {
	return &Engine{
		intent:          "stopped",
		forward:         "stopped",
		tunFactory:      defaultTunFactory,
		delays:          activeDelayRegistry{active: make(map[*delayToken]context.CancelFunc)},
		providers:       providers.NewHub(),
		diag:            diagnostics.NewHub(),
		ruleSetMutation: make(chan struct{}, 1),
		delaySlots:      make(chan struct{}, 8),
	}
}

// SetTunFactory 替换平台 TUN 构造器，仅用于宿主测试；传 nil 恢复默认 sing_tun.New。
func (e *Engine) SetTunFactory(fn func(LC.Tun) (TunHandle, error)) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if fn == nil {
		e.tunFactory = defaultTunFactory
		return
	}
	e.tunFactory = fn
}

// SetPanelAddr 覆盖外部面板监听地址（默认 127.0.0.1:9090），供测试规避宿主机 9090 端口占用。
func (e *Engine) SetPanelAddr(addr string) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.panelAddr = addr
}

func (e *Engine) panelAddressLocked() string {
	if e.panelAddr != "" {
		return e.panelAddr
	}
	return net.JoinHostPort("127.0.0.1", strconv.Itoa(corecfg.PanelPort))
}

// SetUnlockCheck 注册每次 withState 解锁前的不变量校验钩子，仅用于宿主测试。
func (e *Engine) SetUnlockCheck(fn func(*Engine)) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.unlockCheck = fn
}

func (e *Engine) Providers() *providers.Hub {
	return e.providers
}

func (e *Engine) Diagnostics() *diagnostics.Hub {
	return e.diag
}

func (e *Engine) GeoManager() *geo.Manager {
	return e.geo.Load()
}

func (e *Engine) DelaySlots() chan struct{} {
	return e.delaySlots
}

func (e *Engine) TryLockRuleSetMutation() (func(), bool) {
	select {
	case e.ruleSetMutation <- struct{}{}:
		return func() { <-e.ruleSetMutation }, true
	default:
		return nil, false
	}
}

// ObserveProbe 返回无锁只读的运行与自动路线代次，供 probe 处理器做起止双检查。
func (e *Engine) ObserveProbe() (running bool, bootID string, revision uint64, routeToken any, routeRevision uint64) {
	snapshot := e.Status()
	if snapshot == nil || !snapshot.Running {
		return false, "", 0, nil, 0
	}
	routes := e.routes.Load()
	if routes != nil {
		routeRevision = routes.changes.Load()
	}
	return true, snapshot.BootID, snapshot.Revision, routes, routeRevision
}

// ObserveSubfetch 返回无锁只读的运行快照与订阅路由一致性判断，供 subfetch 使用。
func (e *Engine) ObserveSubfetch() (running bool, homeDir, forward string, stillCurrent func() bool) {
	view := e.View()
	if view == nil || !view.Status.Running {
		return false, "", "", nil
	}
	status := view.Status
	return true, view.HomeDir, status.Forward, func() bool {
		return e.subscriptionRouteCurrent(&status)
	}
}

func (e *Engine) diagIdentityLocked() diagnostics.Identity {
	return diagnostics.Identity{
		Running:        e.running,
		BootID:         e.bootID,
		ConfigRevision: e.configRevision,
		CaptureLogs:    e.current.General.CaptureLogs,
	}
}

// withState 是核心写路径的唯一持锁入口。
// defer 后进先出：即使 fn panic，也先解锁 e.mu，再执行 postUnlock 的异步 join，避免锁死内核。
func (e *Engine) withState(fn func(tx *stateTx) error) (err error) {
	tx := &stateTx{e: e}
	defer tx.postUnlock.run()
	e.mu.Lock()
	defer e.mu.Unlock()
	err = fn(tx)
	if e.unlockCheck != nil {
		e.unlockCheck(e)
	}
	return err
}

func (e *Engine) withLifecycle(fn func(tx *stateTx) error) error {
	e.lifecycle.Lock()
	defer e.lifecycle.Unlock()
	return e.withState(fn)
}

func (e *Engine) View() *RuntimeView {
	return e.view.Load()
}

func (e *Engine) Status() *StatusResponse {
	v := e.view.Load()
	if v == nil {
		return nil
	}
	return &v.Status
}

func (e *Engine) ConfigSpec() (ConfigSpec, bool) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.running {
		return ConfigSpec{}, false
	}
	return ConfigSpec{
		BootID:         e.bootID,
		ConfigRevision: e.configRevision,
		Options:        e.current,
	}, true
}

// setCurrentLocked 统一更新 current 并同步刷新 RuntimeView，防止遗漏发布导致快照过期。
func (e *Engine) setCurrentLocked(next corecfg.StartOptions) {
	e.current = next
	e.publishRuntimeLocked()
}

type reloadPlan struct {
	Next                 corecfg.StartOptions
	Cfg                  *config.Config
	Inbound              inboundSettings
	AllowInboundRollback bool
}

// CommitReload 按固定 8 步顺序执行配置热切换，显式返回 applied 标记是否已应用新配置。
// 若 closeBusinessInbounds 失败则返回 applied=false，不退休诊断采集器。
func (tx *stateTx) CommitReload(plan reloadPlan) (bool, error) {
	e := tx.e
	e.cancelDelayTestsLocked()
	e.providers.Invalidate()
	attached := e.tun != nil
	// 始终先屏蔽，避免 executor 接管平台 TUN，也避免失败时暴露部分入口。
	if err := closeBusinessInbounds(); err != nil {
		e.cleanupFailure = errors.Join(e.cleanupFailure, err, e.stopTunLocked())
		resolver.ResetConnection()
		e.publishRuntimeLocked()
		return false, e.cleanupFailure
	}
	tx.deferUnlock(e.diag.BeginReload())
	C.SetConfig(plan.Next.ConfigPath)
	executor.ApplyConfig(withoutBusinessInbounds(plan.Cfg), true)
	e.publishRuleProvidersLocked(plan.Cfg, plan.Inbound.ruleProviderKeys)
	e.desiredInbound = plan.Inbound
	e.current = plan.Next
	e.configRevision++
	tx.deferUnlock(e.diag.EndReload(e.diagIdentityLocked()))
	e.resetProxyIdentitiesLocked()
	e.watchRuntimeRoutesLocked(plan.Cfg)
	e.providers.Reset(providers.Identity{
		BootID: e.bootID, ConfigRevision: e.configRevision, Profile: e.current.Profile, HomeDir: e.current.HomeDir,
	}, plan.Cfg)
	log.Infoln("[ArkClash] reloaded profile %s", plan.Next.Profile)
	var inboundErr error
	if attached {
		inboundErr = e.restoreBusinessInboundsLocked()
		if inboundErr != nil && plan.AllowInboundRollback {
			return true, inboundErr
		}
		if inboundErr != nil {
			e.cleanupFailure = errors.Join(e.cleanupFailure, closeBusinessInbounds(), e.stopTunLocked())
		}
	}
	e.publishRuntimeLocked()
	ctrl.Emit(reloadedEvent{Type: "reloaded", Profile: plan.Next.Profile})
	return true, errors.Join(inboundErr, e.cleanupFailure)
}

// RollbackReload 在新配置已应用但后续原子改名或入口恢复失败时重解析并回滚至 previous。
// 若重解析或回滚热切换也失败，统一进入失败状态（记 cleanupFailure、关闭入口并停掉 TUN、发布快照），
// 避免运行配置与磁盘文件静默分叉。
func (tx *stateTx) RollbackReload(previous corecfg.StartOptions, fallbackInbound inboundSettings) error {
	e := tx.e
	previousInbound := fallbackInbound
	oldCfg, parseErr := parseProfileSettingsConfig(&previous, &previousInbound)
	if parseErr == nil {
		_, parseErr = tx.CommitReload(reloadPlan{
			Next:    previous,
			Cfg:     oldCfg,
			Inbound: previousInbound,
		})
	}
	if parseErr != nil {
		e.cleanupFailure = errors.Join(e.cleanupFailure, closeBusinessInbounds(), e.stopTunLocked(), parseErr)
		e.setCurrentLocked(previous)
		return parseErr
	}
	return nil
}

// ApplyGeoSettings 在核心提交锁下读取并校验 geo-settings.json，按向下锁序
// e.mu -> m.mu 下推给运行中的 geo.Manager，并同步 mihomo 全局 URL 与 current.Geo。
func (e *Engine) ApplyGeoSettings(expectedBootID, revision string) (*geo.Snapshot, int, error) {
	var (
		snapshot *geo.Snapshot
		status   = http.StatusOK
	)
	err := e.withState(func(tx *stateTx) error {
		manager := e.geo.Load()
		if manager == nil {
			status = http.StatusServiceUnavailable
			return errors.New("geo_canceled")
		}
		if expectedBootID != manager.BootID() {
			status = http.StatusConflict
			return errors.New("geo_stale_boot")
		}
		settings, err := geo.ReadSettings(manager.Home())
		if err != nil {
			status = http.StatusBadRequest
			return err
		}
		if settings.Revision != revision {
			status = http.StatusConflict
			return errors.New("geo_invalid_settings")
		}
		if err := manager.ApplySettings(settings); err != nil {
			status = http.StatusServiceUnavailable
			return err
		}
		geo.SetURLs(settings)
		next := e.current
		next.Geo = settings
		e.setCurrentLocked(next)
		snapshot = manager.Snapshot()
		return nil
	})
	return snapshot, status, err
}

// CommitGeoSwap 在核心提交锁下串行执行 Geo 候选落盘与 reader/缓存热换，
// 避免与配置解析期间 mihomo 的 geodata.Init* 并发写盘，并在内容更新后推进运行快照代次。
// 锁序：e.mu -> m.mu。
func (e *Engine) CommitGeoSwap(fn func() (string, error)) (outcome string, err error) {
	err = e.withState(func(tx *stateTx) error {
		var commitErr error
		outcome, commitErr = fn()
		if commitErr != nil {
			return commitErr
		}
		if outcome == "updated" {
			e.publishRuntimeLocked()
		}
		return nil
	})
	return outcome, err
}
