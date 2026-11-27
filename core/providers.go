package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/netip"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"github.com/VOD-Studio/ArkClash/core/internal/ruleset"
	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/component/trie"
	"github.com/metacubex/mihomo/config"
	P "github.com/metacubex/mihomo/constant/provider"
	R "github.com/metacubex/mihomo/rules"
	"github.com/metacubex/mihomo/rules/common"
	"github.com/metacubex/mihomo/tunnel"
	"go.yaml.in/yaml/v3"
)

const (
	providerCandidateLimit = 16 << 20
	providerMaxLines       = 300000
)

var (
	errProviderUnavailable    = errors.New("provider_unavailable")
	errProviderStaleConfig    = errors.New("provider_stale_config")
	errProviderNotFound       = errors.New("provider_not_found")
	errProviderNotUpdatable   = errors.New("provider_not_updatable")
	errProviderNotReplaceable = errors.New("provider_not_replaceable")
	errProviderBusy           = errors.New("provider_busy")
	errProviderInvalidRequest = errors.New("provider_invalid_request")
	errProviderInvalidContent = errors.New("provider_invalid_content")
	errProviderTimeout        = errors.New("provider_timeout")
	errProviderUpdateFailed   = errors.New("provider_update_failed")
	errProviderIO             = errors.New("provider_io")
)

type runtimeProviderItem struct {
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

type runtimeProvidersSnapshot struct {
	BootID         string                `json:"bootId"`
	ConfigRevision uint64                `json:"configRevision"`
	Profile        string                `json:"profile"`
	Revision       uint64                `json:"revision"`
	Items          []runtimeProviderItem `json:"items"`
}

type providerOpState struct {
	phase   string
	outcome string
	errCode string
}

type providerUpdateBody struct {
	BootID         string `json:"bootId"`
	ConfigRevision uint64 `json:"configRevision"`
	Kind           string `json:"kind"`
	Name           string `json:"name"`
}

type providerReplaceBody struct {
	BootID         string `json:"bootId"`
	ConfigRevision uint64 `json:"configRevision"`
	Kind           string `json:"kind"`
	Name           string `json:"name"`
	Candidate      string `json:"candidate"`
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

type providerManager struct {
	mu             sync.Mutex
	bootID         string
	configRevision uint64
	profile        string
	homeDir        string
	revision       uint64
	closed         bool
	proxyProviders map[string]P.ProxyProvider
	ruleProviders  map[string]P.RuleProvider
	states         map[string]providerOpState
	busy           map[string]bool
	snapshot       atomic.Pointer[runtimeProvidersSnapshot]
	subscriptions  []io.Closer
	wake           chan struct{}
	done           chan struct{}
	wg             sync.WaitGroup
}

type providerEventHub struct {
	mu          sync.Mutex
	subscribers map[chan *runtimeProvidersSnapshot]struct{}
}

var (
	activeProviders atomic.Pointer[providerManager]
	providerHub     = &providerEventHub{subscribers: make(map[chan *runtimeProvidersSnapshot]struct{})}
)

func providerKey(kind, name string) string {
	return kind + "\x00" + name
}

func (hub *providerEventHub) publish(snapshot *runtimeProvidersSnapshot) {
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

func (hub *providerEventHub) closeAll() {
	hub.mu.Lock()
	for ch := range hub.subscribers {
		delete(hub.subscribers, ch)
		close(ch)
	}
	hub.mu.Unlock()
}

func providerBehaviorString(behavior P.RuleBehavior) string {
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

func providerFormatString(format P.RuleFormat) string {
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

func providerVehicleString(vt P.VehicleType) string {
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

func isManagedRuleProvider(name string) bool {
	return ruleset.IsManagedName(name)
}

func invalidateProviderManagerLocked() {
	prev := activeProviders.Swap(nil)
	if prev != nil {
		prev.close()
	}
}

// 调用方持有核心 mu；每次配置启动或热切换都建立绑定当前 bootId/configRevision 的新管理器。
func resetProviderManagerLocked(cfg *config.Config) {
	invalidateProviderManagerLocked()
	manager := &providerManager{
		bootID:         runtimeBootID,
		configRevision: runtimeConfigRevision,
		profile:        current.Profile,
		homeDir:        current.HomeDir,
		proxyProviders: make(map[string]P.ProxyProvider),
		ruleProviders:  make(map[string]P.RuleProvider),
		states:         make(map[string]providerOpState),
		busy:           make(map[string]bool),
		wake:           make(chan struct{}, 1),
		done:           make(chan struct{}),
	}
	if cfg != nil {
		for name, item := range cfg.Providers {
			if providerVehicleString(item.VehicleType()) == "" {
				continue
			}
			manager.proxyProviders[name] = item
		}
		for name, item := range cfg.RuleProviders {
			if isManagedRuleProvider(name) || providerVehicleString(item.VehicleType()) == "" {
				continue
			}
			manager.ruleProviders[name] = item
		}
	}
	manager.mu.Lock()
	snap := manager.rebuildSnapshotLocked()
	manager.mu.Unlock()
	activeProviders.Store(manager)
	manager.startWatch()
	providerHub.publish(snap)
}

func closeProviderManagerLocked() *providerManager {
	prev := activeProviders.Swap(nil)
	if prev != nil {
		prev.close()
	}
	providerHub.closeAll()
	return prev
}

func (m *providerManager) startWatch() {
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
			if activeProviders.Load() != m || item == nil {
				return
			}
			if _, ok := m.proxyProviders[item.Name()]; ok {
				notify()
			}
		}),
		tunnel.Tunnel.RuleUpdateCallback().Register(func(item P.RuleProvider) {
			if activeProviders.Load() != m || item == nil {
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
			if m.closed || activeProviders.Load() != m {
				m.mu.Unlock()
				return
			}
			snap := m.rebuildSnapshotLocked()
			m.mu.Unlock()
			providerHub.publish(snap)
		}
	}()
}

func (m *providerManager) close() {
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

func (m *providerManager) wait() {
	m.wg.Wait()
}

func (m *providerManager) isClosed() bool {
	m.mu.Lock()
	closed := m.closed || activeProviders.Load() != m
	m.mu.Unlock()
	return closed
}

func providerUpdatedMillis(item any) int64 {
	if timed, ok := item.(updatedAtProvider); ok {
		ts := timed.ArkClashUpdatedAt()
		if !ts.IsZero() {
			return ts.UnixMilli()
		}
	}
	return 0
}

func (m *providerManager) rebuildSnapshotLocked() *runtimeProvidersSnapshot {
	m.revision++
	items := make([]runtimeProviderItem, 0, len(m.proxyProviders)+len(m.ruleProviders))
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
		items = append(items, runtimeProviderItem{
			Kind:        "proxy",
			Name:        name,
			VehicleType: providerVehicleString(vt),
			Count:       item.Count(),
			UpdatedAt:   providerUpdatedMillis(item),
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
			format = providerFormatString(formatted.ArkClashFormat())
		}
		items = append(items, runtimeProviderItem{
			Kind:        "rule",
			Name:        name,
			VehicleType: providerVehicleString(vt),
			Count:       item.Count(),
			UpdatedAt:   providerUpdatedMillis(item),
			Behavior:    providerBehaviorString(item.Behavior()),
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
	snap := &runtimeProvidersSnapshot{
		BootID:         m.bootID,
		ConfigRevision: m.configRevision,
		Profile:        m.profile,
		Revision:       m.revision,
		Items:          items,
	}
	m.snapshot.Store(snap)
	return snap
}

func (m *providerManager) currentSnapshot() *runtimeProvidersSnapshot {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed {
		return m.snapshot.Load()
	}
	return m.rebuildSnapshotLocked()
}

func getRuntimeProviders(w http.ResponseWriter, r *http.Request) {
	manager := activeProviders.Load()
	if manager == nil {
		writeError(w, r, http.StatusServiceUnavailable, errProviderUnavailable)
		return
	}
	snap := manager.currentSnapshot()
	if snap == nil {
		writeError(w, r, http.StatusServiceUnavailable, errProviderUnavailable)
		return
	}
	render.JSON(w, r, snap)
}

func getRuntimeProviderEvents(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet || !strings.EqualFold(r.Header.Get("Upgrade"), "websocket") || r.Header.Get("Sec-WebSocket-Key") == "" {
		writeError(w, r, http.StatusBadRequest, errProviderInvalidRequest)
		return
	}
	manager := activeProviders.Load()
	if manager == nil {
		writeError(w, r, http.StatusServiceUnavailable, errProviderUnavailable)
		return
	}
	channel := make(chan *runtimeProvidersSnapshot, 1)
	providerHub.mu.Lock()
	snap := manager.currentSnapshot()
	if snap == nil || manager.isClosed() {
		providerHub.mu.Unlock()
		writeError(w, r, http.StatusServiceUnavailable, errProviderUnavailable)
		return
	}
	providerHub.subscribers[channel] = struct{}{}
	channel <- snap
	providerHub.mu.Unlock()
	defer func() {
		providerHub.mu.Lock()
		delete(providerHub.subscribers, channel)
		providerHub.mu.Unlock()
	}()
	conn, rw, err := upgradeWebSocket(w, r)
	if err != nil {
		return
	}
	defer conn.Close()
	closed := make(chan struct{})
	go func() {
		_, _ = io.Copy(io.Discard, rw)
		close(closed)
	}()
	for {
		select {
		case snapshot, ok := <-channel:
			if !ok {
				return
			}
			data, err := json.Marshal(struct {
				Type     string                    `json:"type"`
				Snapshot *runtimeProvidersSnapshot `json:"snapshot"`
			}{Type: "providers", Snapshot: snapshot})
			if err != nil {
				return
			}
			if err := conn.SetWriteDeadline(time.Now().Add(5 * time.Second)); err != nil {
				return
			}
			if err := writeTextFrame(conn, data); err != nil {
				return
			}
		case <-closed:
			return
		}
	}
}

func sanitizeProviderUpdateError(err error) string {
	if err == nil {
		return ""
	}
	if errors.Is(err, context.DeadlineExceeded) || os.IsTimeout(err) {
		return errProviderTimeout.Error()
	}
	return errProviderUpdateFailed.Error()
}

func postRuntimeProviderUpdate(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	var body providerUpdateBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil ||
		(body.Kind != "proxy" && body.Kind != "rule") || body.Name == "" ||
		body.BootID == "" || body.ConfigRevision == 0 {
		writeError(w, r, http.StatusBadRequest, errProviderInvalidRequest)
		return
	}
	manager := activeProviders.Load()
	if manager == nil {
		writeError(w, r, http.StatusServiceUnavailable, errProviderUnavailable)
		return
	}
	key := providerKey(body.Kind, body.Name)
	var target updatableProvider
	manager.mu.Lock()
	if manager.closed || activeProviders.Load() != manager ||
		manager.bootID != body.BootID || manager.configRevision != body.ConfigRevision {
		manager.mu.Unlock()
		writeError(w, r, http.StatusConflict, errProviderStaleConfig)
		return
	}
	if body.Kind == "proxy" {
		item, ok := manager.proxyProviders[body.Name]
		if !ok {
			manager.mu.Unlock()
			writeError(w, r, http.StatusNotFound, errProviderNotFound)
			return
		}
		if item.VehicleType() != P.HTTP {
			manager.mu.Unlock()
			writeError(w, r, http.StatusBadRequest, errProviderNotUpdatable)
			return
		}
		target, ok = item.(updatableProvider)
		if !ok {
			manager.mu.Unlock()
			writeError(w, r, http.StatusBadRequest, errProviderNotUpdatable)
			return
		}
	} else {
		item, ok := manager.ruleProviders[body.Name]
		if !ok {
			manager.mu.Unlock()
			writeError(w, r, http.StatusNotFound, errProviderNotFound)
			return
		}
		if item.VehicleType() != P.HTTP {
			manager.mu.Unlock()
			writeError(w, r, http.StatusBadRequest, errProviderNotUpdatable)
			return
		}
		target, ok = item.(updatableProvider)
		if !ok {
			manager.mu.Unlock()
			writeError(w, r, http.StatusBadRequest, errProviderNotUpdatable)
			return
		}
	}
	if manager.busy[key] {
		manager.mu.Unlock()
		writeError(w, r, http.StatusConflict, errProviderBusy)
		return
	}
	manager.busy[key] = true
	manager.states[key] = providerOpState{phase: "updating", outcome: "none", errCode: ""}
	manager.wg.Add(1)
	startSnap := manager.rebuildSnapshotLocked()
	manager.mu.Unlock()
	defer manager.wg.Done()
	providerHub.publish(startSnap)

	var changed bool
	var opErr error
	if !manager.isClosed() {
		changed, opErr = target.ArkClashUpdate()
	} else {
		opErr = errProviderStaleConfig
	}

	manager.mu.Lock()
	delete(manager.busy, key)
	if manager.closed || activeProviders.Load() != manager ||
		manager.bootID != body.BootID || manager.configRevision != body.ConfigRevision {
		manager.mu.Unlock()
		writeError(w, r, http.StatusConflict, errProviderStaleConfig)
		return
	}
	if opErr != nil {
		code := sanitizeProviderUpdateError(opErr)
		manager.states[key] = providerOpState{phase: "idle", outcome: "failed", errCode: code}
		snap := manager.rebuildSnapshotLocked()
		manager.mu.Unlock()
		providerHub.publish(snap)
		status := http.StatusBadGateway
		if code == errProviderTimeout.Error() {
			status = http.StatusGatewayTimeout
		}
		writeError(w, r, status, errors.New(code))
		return
	}
	outcome := "unchanged"
	if changed {
		outcome = "updated"
	}
	manager.states[key] = providerOpState{phase: "idle", outcome: outcome, errCode: ""}
	snap := manager.rebuildSnapshotLocked()
	manager.mu.Unlock()
	providerHub.publish(snap)
	render.JSON(w, r, snap)
}

func checkProviderCandidatePath(homeDir, candidate string) error {
	if candidate == "" {
		return errProviderInvalidRequest
	}
	clean := filepath.Clean(candidate)
	dir := filepath.Dir(clean)
	if dir != filepath.Join(homeDir, "profile-work") && dir != filepath.Join(homeDir, "profiles") {
		return errProviderInvalidRequest
	}
	return nil
}

func readProviderCandidate(homeDir, candidate string) ([]byte, error) {
	if err := checkProviderCandidatePath(homeDir, candidate); err != nil {
		return nil, err
	}
	info, err := os.Lstat(candidate)
	if err != nil {
		return nil, errProviderIO
	}
	if !info.Mode().IsRegular() {
		return nil, errProviderInvalidRequest
	}
	if info.Size() <= 0 || info.Size() > providerCandidateLimit {
		return nil, errProviderInvalidContent
	}
	file, err := os.Open(candidate)
	if err != nil {
		return nil, errProviderIO
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, providerCandidateLimit+1))
	if err != nil {
		return nil, errProviderIO
	}
	if len(data) == 0 || len(data) > providerCandidateLimit {
		return nil, errProviderInvalidContent
	}
	return data, nil
}

// 严格按当前 rule-provider 的 behavior 与 format 校验候选内容，防止 mihomo 静默跳过坏行导致规则被清空。
func validateRuleProviderCandidate(data []byte, behavior P.RuleBehavior, format P.RuleFormat) error {
	if len(data) == 0 || len(data) > providerCandidateLimit {
		return errProviderInvalidContent
	}
	if format == P.MrsRule {
		if len(data) > ruleset.InputLimit || !ruleset.ValidateMRS(data, behavior) {
			return errProviderInvalidContent
		}
		return nil
	}
	if !utf8.Valid(data) || bytes.IndexByte(data, 0) >= 0 {
		return errProviderInvalidContent
	}
	trimmed := bytes.TrimPrefix(data, []byte("\xef\xbb\xbf"))
	var lines []string
	switch format {
	case P.YamlRule:
		var root yaml.Node
		decoder := yaml.NewDecoder(bytes.NewReader(trimmed))
		if decoder.Decode(&root) != nil || decoder.Decode(new(yaml.Node)) != io.EOF ||
			len(root.Content) != 1 || root.Content[0].Kind != yaml.MappingNode {
			return errProviderInvalidContent
		}
		fields := root.Content[0].Content
		for i := 0; i < len(fields); i += 2 {
			if fields[i].Value != "payload" && fields[i].Value != "rules" {
				continue
			}
			list := fields[i+1]
			if lines != nil || list.Kind != yaml.SequenceNode || len(list.Content) > providerMaxLines {
				return errProviderInvalidContent
			}
			lines = make([]string, 0, len(list.Content))
			for _, node := range list.Content {
				if node.Kind != yaml.ScalarNode {
					return errProviderInvalidContent
				}
				lines = append(lines, node.Value)
			}
		}
	case P.TextRule:
		for line := range strings.SplitSeq(string(trimmed), "\n") {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, "//") {
				continue
			}
			if len(lines) >= providerMaxLines {
				return errProviderInvalidContent
			}
			lines = append(lines, line)
		}
	default:
		return errProviderInvalidContent
	}
	if len(lines) == 0 {
		return errProviderInvalidContent
	}
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || len(line) > 2048 || strings.ContainsAny(line, "\x00\r\n") ||
			strings.HasPrefix(line, "#") || strings.HasPrefix(line, "//") {
			return errProviderInvalidContent
		}
		switch behavior {
		case P.Domain:
			if strings.ContainsRune(line, '/') {
				return errProviderInvalidContent
			}
			if _, err := trie.ValidAndSplitDomain(line); err != nil {
				return errProviderInvalidContent
			}
		case P.IPCIDR:
			if _, err := netip.ParsePrefix(line); err != nil {
				return errProviderInvalidContent
			}
		case P.Classical:
			ruleType, payload, target, params := common.ParseRulePayload(line, false)
			switch ruleType {
			case "MATCH", "RULE-SET", "SUB-RULE":
				return errProviderInvalidContent
			}
			if _, err := R.ParseRule(ruleType, payload, target, params, nil); err != nil {
				return errProviderInvalidContent
			}
		default:
			return errProviderInvalidContent
		}
	}
	return nil
}

func postRuntimeProviderReplace(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	var body providerReplaceBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil ||
		(body.Kind != "proxy" && body.Kind != "rule") || body.Name == "" ||
		body.BootID == "" || body.ConfigRevision == 0 || body.Candidate == "" {
		writeError(w, r, http.StatusBadRequest, errProviderInvalidRequest)
		return
	}
	manager := activeProviders.Load()
	if manager == nil {
		writeError(w, r, http.StatusServiceUnavailable, errProviderUnavailable)
		return
	}
	key := providerKey(body.Kind, body.Name)
	var target replaceableProvider
	var ruleBehavior P.RuleBehavior
	var ruleFormat P.RuleFormat
	var homeDir string
	manager.mu.Lock()
	if manager.closed || activeProviders.Load() != manager ||
		manager.bootID != body.BootID || manager.configRevision != body.ConfigRevision {
		manager.mu.Unlock()
		writeError(w, r, http.StatusConflict, errProviderStaleConfig)
		return
	}
	homeDir = manager.homeDir
	if body.Kind == "proxy" {
		item, ok := manager.proxyProviders[body.Name]
		if !ok {
			manager.mu.Unlock()
			writeError(w, r, http.StatusNotFound, errProviderNotFound)
			return
		}
		if item.VehicleType() != P.HTTP && item.VehicleType() != P.File {
			manager.mu.Unlock()
			writeError(w, r, http.StatusBadRequest, errProviderNotReplaceable)
			return
		}
		target, ok = item.(replaceableProvider)
		if !ok {
			manager.mu.Unlock()
			writeError(w, r, http.StatusBadRequest, errProviderNotReplaceable)
			return
		}
	} else {
		item, ok := manager.ruleProviders[body.Name]
		if !ok {
			manager.mu.Unlock()
			writeError(w, r, http.StatusNotFound, errProviderNotFound)
			return
		}
		if item.VehicleType() != P.HTTP && item.VehicleType() != P.File {
			manager.mu.Unlock()
			writeError(w, r, http.StatusBadRequest, errProviderNotReplaceable)
			return
		}
		target, ok = item.(replaceableProvider)
		formatted, hasFormat := item.(ruleFormatProvider)
		if !ok || !hasFormat {
			manager.mu.Unlock()
			writeError(w, r, http.StatusBadRequest, errProviderNotReplaceable)
			return
		}
		ruleBehavior = item.Behavior()
		ruleFormat = formatted.ArkClashFormat()
	}
	if err := checkProviderCandidatePath(homeDir, body.Candidate); err != nil {
		manager.mu.Unlock()
		writeError(w, r, http.StatusBadRequest, err)
		return
	}
	if manager.busy[key] {
		manager.mu.Unlock()
		writeError(w, r, http.StatusConflict, errProviderBusy)
		return
	}
	manager.busy[key] = true
	manager.states[key] = providerOpState{phase: "updating", outcome: "none", errCode: ""}
	manager.wg.Add(1)
	startSnap := manager.rebuildSnapshotLocked()
	manager.mu.Unlock()
	defer manager.wg.Done()
	providerHub.publish(startSnap)

	var changed bool
	var opErr error
	data, readErr := readProviderCandidate(homeDir, body.Candidate)
	if readErr != nil {
		opErr = readErr
	} else if body.Kind == "rule" {
		opErr = validateRuleProviderCandidate(data, ruleBehavior, ruleFormat)
	}
	if opErr == nil {
		if manager.isClosed() {
			opErr = errProviderStaleConfig
		} else {
			changed, opErr = target.ArkClashReplace(data)
			if opErr != nil {
				opErr = errProviderInvalidContent
			}
		}
	}

	manager.mu.Lock()
	delete(manager.busy, key)
	if manager.closed || activeProviders.Load() != manager ||
		manager.bootID != body.BootID || manager.configRevision != body.ConfigRevision {
		manager.mu.Unlock()
		writeError(w, r, http.StatusConflict, errProviderStaleConfig)
		return
	}
	if opErr != nil {
		code := errProviderInvalidContent.Error()
		status := http.StatusUnprocessableEntity
		switch {
		case errors.Is(opErr, errProviderInvalidRequest):
			code = errProviderInvalidRequest.Error()
			status = http.StatusBadRequest
		case errors.Is(opErr, errProviderIO):
			code = errProviderIO.Error()
			status = http.StatusInternalServerError
		}
		manager.states[key] = providerOpState{phase: "idle", outcome: "failed", errCode: code}
		snap := manager.rebuildSnapshotLocked()
		manager.mu.Unlock()
		providerHub.publish(snap)
		writeError(w, r, status, errors.New(code))
		return
	}
	outcome := "unchanged"
	if changed {
		outcome = "updated"
	}
	manager.states[key] = providerOpState{phase: "idle", outcome: outcome, errCode: ""}
	snap := manager.rebuildSnapshotLocked()
	manager.mu.Unlock()
	providerHub.publish(snap)
	render.JSON(w, r, snap)
}
