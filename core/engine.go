package main

import (
	"context"
	"sync"
	"sync/atomic"

	"github.com/VOD-Studio/ArkClash/core/internal/providers"
	"github.com/metacubex/http"
	C "github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/tunnel"
)

// runtimeView 是 Tier 1 无锁只读热路径快照，在每次持有 eng.mu 的提交点原子整体替换。
// 调用方不得修改返回快照中的任何字段。
type runtimeView struct {
	Status          statusResponse
	HomeDir         string
	StoreGeneration string
	CaptureLogs     bool
	DelayTimeout    int
}

// configSpec 是 Tier 2 锁外慢路径（配置预览、QuickJS 脚本执行、规则集预检）使用的配置规格浅拷贝。
// 不变量：startOptions 及其嵌套结构中的切片和 map（如 Hosts、Rules、Profiles、Items 等）
// 只能整体替换，禁止原地修改，保证锁外读取安全。
type configSpec struct {
	BootID         string
	ConfigRevision uint64
	Options        startOptions
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
	e          *coreEngine
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
	active map[*http.Request]context.CancelFunc
}

type coreEngine struct {
	// 顶层生命周期串行锁：串行 start / attachTun / detachTun / stop，
	// 保证 stop 解锁 e.mu 后的异步 worker join 全部完成后才允许下一次 start。
	lifecycle sync.Mutex

	// 核心提交锁。严格单向锁序：
	// lifecycle -> e.mu -> {providers.mu, geo.mu, diag.mu -> collector.mu -> statsMu}
	mu sync.Mutex

	// 1. 生命周期与运行身份
	running        bool
	current        startOptions
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
	tun               tunHandle
	tunCloseErr       error
	tunCloseAttempted bool
	tunFactory        func(LC.Tun) (tunHandle, error)
	panel             *panelController
	// panelOpSeq 永不单独复位，避免新操作号命中尚未清空的 selections 去重表。
	panelOpSeq atomic.Uint64

	// 3. 绑定当前配置代次的辅助状态
	proxies    proxyIdentityTable
	selections selectionDedupLog
	delays     activeDelayRegistry

	// 4. 无锁只读快照
	view atomic.Pointer[runtimeView]

	// 5. 下游独立子系统与路线监听
	providers *providers.Hub
	routes    atomic.Pointer[runtimeRouteWatch]
}

// 仅宿主测试在 TestMain 挂载，用于在 withState 解锁前校验 view 与核心状态一致。
var engineUnlockCheck func(*coreEngine)

var eng = newCoreEngine()

func defaultTunFactory(options LC.Tun) (tunHandle, error) {
	l, err := sing_tun.New(options, tunnel.Tunnel)
	if err != nil {
		// 显式返回无类型 nil，避免 (*sing_tun.Listener)(nil) 落入 tun != nil 判断。
		return nil, err
	}
	return l, nil
}

func newCoreEngine() *coreEngine {
	return &coreEngine{
		intent:     "stopped",
		forward:    "stopped",
		tunFactory: defaultTunFactory,
		delays:     activeDelayRegistry{active: make(map[*http.Request]context.CancelFunc)},
		providers:  providers.NewHub(),
	}
}

// withState 是核心写路径的唯一持锁入口。
// defer 后进先出：即使 fn panic，也先解锁 e.mu，再执行 postUnlock 的异步 join，避免锁死内核。
func (e *coreEngine) withState(fn func(tx *stateTx) error) (err error) {
	tx := &stateTx{e: e}
	defer tx.postUnlock.run()
	e.mu.Lock()
	defer e.mu.Unlock()
	err = fn(tx)
	if engineUnlockCheck != nil {
		engineUnlockCheck(e)
	}
	return err
}

func (e *coreEngine) withLifecycle(fn func(tx *stateTx) error) error {
	e.lifecycle.Lock()
	defer e.lifecycle.Unlock()
	return e.withState(fn)
}

func (e *coreEngine) View() *runtimeView {
	return e.view.Load()
}

func (e *coreEngine) Status() *statusResponse {
	v := e.view.Load()
	if v == nil {
		return nil
	}
	return &v.Status
}

func (e *coreEngine) ConfigSpec() (configSpec, bool) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.running {
		return configSpec{}, false
	}
	return configSpec{
		BootID:         e.bootID,
		ConfigRevision: e.configRevision,
		Options:        e.current,
	}, true
}

// setCurrentLocked 统一更新 current 并同步刷新 runtimeView，防止遗漏发布导致快照过期。
func (e *coreEngine) setCurrentLocked(next startOptions) {
	e.current = next
	e.publishRuntimeLocked()
}
