// Package providers 管理运行中的 proxy-provider 与 rule-provider 状态快照、刷新、替换及事件流，不依赖核心锁 core.mu。
package providers

import (
	"errors"
	"io"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/VOD-Studio/ArkClash/core/internal/ruleset"
	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/config"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/tunnel"
)

var (
	errUnavailable    = errors.New("provider_unavailable")
	errStaleConfig    = errors.New("provider_stale_config")
	errNotFound       = errors.New("provider_not_found")
	errNotUpdatable   = errors.New("provider_not_updatable")
	errNotReplaceable = errors.New("provider_not_replaceable")
	errBusy           = errors.New("provider_busy")
	errInvalidRequest = errors.New("provider_invalid_request")
	errInvalidContent = errors.New("provider_invalid_content")
	errTimeout        = errors.New("provider_timeout")
	errUpdateFailed   = errors.New("provider_update_failed")
	errIO             = errors.New("provider_io")
)

// Identity 绑定当前运行的内核代次与配置沙箱目录，由调用方按值传入。
type Identity struct {
	BootID         string
	ConfigRevision uint64
	Profile        string
	HomeDir        string
}

type Item struct {
	Kind        string `json:"kind"`
	Name        string `json:"name"`
	VehicleType string `json:"vehicleType"`
	Count       int    `json:"count"`
	UpdatedAt   int64  `json:"updatedAt"`
	Behavior    string `json:"behavior,omitempty"`
	Format      string `json:"format,omitempty"`
	Updatable   bool   `json:"updatable"`
	Replaceable bool   `json:"replaceable"`
	Phase       string `json:"phase"`
	Outcome     string `json:"outcome"`
	Error       string `json:"error"`
}

type Snapshot struct {
	BootID         string `json:"bootId"`
	ConfigRevision uint64 `json:"configRevision"`
	Profile        string `json:"profile"`
	Revision       uint64 `json:"revision"`
	Items          []Item `json:"items"`
}

type UpdateRequest struct {
	BootID         string `json:"bootId"`
	ConfigRevision uint64 `json:"configRevision"`
	Kind           string `json:"kind"`
	Name           string `json:"name"`
}

type ReplaceRequest struct {
	BootID         string `json:"bootId"`
	ConfigRevision uint64 `json:"configRevision"`
	Kind           string `json:"kind"`
	Name           string `json:"name"`
	Candidate      string `json:"candidate"`
}

type opState struct {
	phase   string
	outcome string
	errCode string
}

type updatableProvider interface {
	ArkClashUpdate() (bool, error)
}

type replaceableProvider interface {
	ArkClashReplace([]byte) (bool, error)
}

type updatedAtProvider interface {
	ArkClashUpdatedAt() time.Time
}

type ruleFormatProvider interface {
	ArkClashFormat() P.RuleFormat
}

type manager struct {
	hub            *Hub
	mu             sync.Mutex
	bootID         string
	configRevision uint64
	profile        string
	homeDir        string
	revision       uint64
	closed         bool
	proxyProviders map[string]P.ProxyProvider
	ruleProviders  map[string]P.RuleProvider
	states         map[string]opState
	busy           map[string]bool
	snapshot       atomic.Pointer[Snapshot]
	subscriptions  []io.Closer
	wake           chan struct{}
	done           chan struct{}
	wg             sync.WaitGroup
}

type eventHub struct {
	mu          sync.Mutex
	subscribers map[chan *Snapshot]struct{}
}

// Hub 维护当前活跃配置对应的 provider 管理器和 WebSocket 订阅者集合。
type Hub struct {
	active atomic.Pointer[manager]
	events eventHub
}

func NewHub() *Hub {
	return &Hub{
		events: eventHub{subscribers: make(map[chan *Snapshot]struct{})},
	}
}

func providerKey(kind, name string) string {
	return kind + "\x00" + name
}

func (hub *eventHub) publish(snapshot *Snapshot) {
	if snapshot == nil {
		return
	}
	hub.mu.Lock()
	for ch := range hub.subscribers {
		select {
		case ch <- snapshot:
		default:
			select {
			case <-ch:
			default:
			}
			select {
			case ch <- snapshot:
			default:
			}
		}
	}
	hub.mu.Unlock()
}

func (hub *eventHub) closeAll() {
	hub.mu.Lock()
	for ch := range hub.subscribers {
		delete(hub.subscribers, ch)
		close(ch)
	}
	hub.mu.Unlock()
}

func behaviorString(behavior P.RuleBehavior) string {
	switch behavior {
	case P.Domain:
		return "domain"
	case P.IPCIDR:
		return "ipcidr"
	case P.Classical:
		return "classical"
	default:
		return strings.ToLower(behavior.String())
	}
}

func formatString(format P.RuleFormat) string {
	switch format {
	case P.YamlRule:
		return "yaml"
	case P.TextRule:
		return "text"
	case P.MrsRule:
		return "mrs"
	default:
		return strings.ToLower(format.String())
	}
}

func vehicleString(vt P.VehicleType) string {
	switch vt {
	case P.HTTP:
		return "http"
	case P.File:
		return "file"
	case P.Inline:
		return "inline"
	default:
		return ""
	}
}

func (h *Hub) Invalidate() {
	prev := h.active.Swap(nil)
	if prev != nil {
		prev.close()
	}
}

// Reset 每次配置启动或热切换都建立绑定当前 bootId/configRevision 的新管理器。
func (h *Hub) Reset(id Identity, cfg *config.Config) {
	h.Invalidate()
	m := &manager{
		hub:            h,
		bootID:         id.BootID,
		configRevision: id.ConfigRevision,
		profile:        id.Profile,
		homeDir:        id.HomeDir,
		proxyProviders: make(map[string]P.ProxyProvider),
		ruleProviders:  make(map[string]P.RuleProvider),
		states:         make(map[string]opState),
		busy:           make(map[string]bool),
		wake:           make(chan struct{}, 1),
		done:           make(chan struct{}),
	}
	if cfg != nil {
		for name, item := range cfg.Providers {
			if vehicleString(item.VehicleType()) == "" {
				continue
			}
			m.proxyProviders[name] = item
		}
		for name, item := range cfg.RuleProviders {
			if ruleset.IsManagedName(name) || vehicleString(item.VehicleType()) == "" {
				continue
			}
			m.ruleProviders[name] = item
		}
	}
	m.mu.Lock()
	snap := m.rebuildSnapshotLocked()
	m.mu.Unlock()
	h.active.Store(m)
	m.startWatch()
	h.events.publish(snap)
}

// Close 停止当前管理器并关闭全部事件订阅；返回的等待函数供调用方在释放外层锁后调用。
func (h *Hub) Close() func() {
	prev := h.active.Swap(nil)
	if prev != nil {
		prev.close()
	}
	h.events.closeAll()
	if prev == nil {
		return func() {}
	}
	return prev.wait
}

func (m *manager) startWatch() {
	if len(m.proxyProviders) == 0 && len(m.ruleProviders) == 0 {
		return
	}
	notify := func() {
		select {
		case m.wake <- struct{}{}:
		default:
		}
	}
	m.subscriptions = []io.Closer{
		provider.ProxyUpdateCallback().Register(func(item P.ProxyProvider) {
			if m.hub.active.Load() != m || item == nil {
				return
			}
			if _, ok := m.proxyProviders[item.Name()]; ok {
				notify()
			}
		}),
		tunnel.Tunnel.RuleUpdateCallback().Register(func(item P.RuleProvider) {
			if m.hub.active.Load() != m || item == nil {
				return
			}
			if _, ok := m.ruleProviders[item.Name()]; ok {
				notify()
			}
		}),
	}
	m.wg.Add(1)
	go func() {
		defer m.wg.Done()
		for {
			select {
			case <-m.done:
				return
			case <-m.wake:
			}
			m.mu.Lock()
			if m.closed || m.hub.active.Load() != m {
				m.mu.Unlock()
				return
			}
			snap := m.rebuildSnapshotLocked()
			m.mu.Unlock()
			m.hub.events.publish(snap)
		}
	}()
}

func (m *manager) close() {
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return
	}
	m.closed = true
	subs := m.subscriptions
	m.subscriptions = nil
	close(m.done)
	m.mu.Unlock()
	for _, sub := range subs {
		_ = sub.Close()
	}
}

func (m *manager) wait() {
	m.wg.Wait()
}

func (m *manager) isClosed() bool {
	m.mu.Lock()
	closed := m.closed || m.hub.active.Load() != m
	m.mu.Unlock()
	return closed
}

func updatedMillis(item any) int64 {
	if timed, ok := item.(updatedAtProvider); ok {
		ts := timed.ArkClashUpdatedAt()
		if !ts.IsZero() {
			return ts.UnixMilli()
		}
	}
	return 0
}

func (m *manager) rebuildSnapshotLocked() *Snapshot {
	m.revision++
	items := make([]Item, 0, len(m.proxyProviders)+len(m.ruleProviders))
	for name, item := range m.proxyProviders {
		vt := item.VehicleType()
		state := m.states[providerKey("proxy", name)]
		phase := state.phase
		if phase == "" {
			phase = "idle"
		}
		outcome := state.outcome
		if outcome == "" {
			outcome = "none"
		}
		items = append(items, Item{
			Kind:        "proxy",
			Name:        name,
			VehicleType: vehicleString(vt),
			Count:       item.Count(),
			UpdatedAt:   updatedMillis(item),
			Updatable:   vt == P.HTTP,
			Replaceable: vt == P.HTTP || vt == P.File,
			Phase:       phase,
			Outcome:     outcome,
			Error:       state.errCode,
		})
	}
	for name, item := range m.ruleProviders {
		vt := item.VehicleType()
		state := m.states[providerKey("rule", name)]
		phase := state.phase
		if phase == "" {
			phase = "idle"
		}
		outcome := state.outcome
		if outcome == "" {
			outcome = "none"
		}
		format := ""
		if formatted, ok := item.(ruleFormatProvider); ok {
			format = formatString(formatted.ArkClashFormat())
		}
		items = append(items, Item{
			Kind:        "rule",
			Name:        name,
			VehicleType: vehicleString(vt),
			Count:       item.Count(),
			UpdatedAt:   updatedMillis(item),
			Behavior:    behaviorString(item.Behavior()),
			Format:      format,
			Updatable:   vt == P.HTTP,
			Replaceable: vt == P.HTTP || vt == P.File,
			Phase:       phase,
			Outcome:     outcome,
			Error:       state.errCode,
		})
	}
	sort.Slice(items, func(i, j int) bool {
		if items[i].Kind != items[j].Kind {
			return items[i].Kind < items[j].Kind
		}
		return items[i].Name < items[j].Name
	})
	snap := &Snapshot{
		BootID:         m.bootID,
		ConfigRevision: m.configRevision,
		Profile:        m.profile,
		Revision:       m.revision,
		Items:          items,
	}
	m.snapshot.Store(snap)
	return snap
}

func (m *manager) currentSnapshot() *Snapshot {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed {
		return m.snapshot.Load()
	}
	return m.rebuildSnapshotLocked()
}
