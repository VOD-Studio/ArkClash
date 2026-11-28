package providers

import (
	"encoding/json"
	"errors"
	"io"
	"strings"
	"time"

	"github.com/VOD-Studio/ArkClash/core/internal/ctrl"
	"github.com/metacubex/chi"
	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
	P "github.com/metacubex/mihomo/constant/provider"
)

func (h *Hub) RegisterRoutes(r chi.Router) {
	r.Get("/providers", h.HandleList)
	r.Get("/providers/events", h.HandleEvents)
	r.Post("/providers/update", h.HandleUpdate)
	r.Post("/providers/replace", h.HandleReplace)
}

func (h *Hub) HandleList(w http.ResponseWriter, r *http.Request) {
	m := h.active.Load()
	if m == nil {
		ctrl.WriteError(w, r, http.StatusServiceUnavailable, errUnavailable)
		return
	}
	snap := m.currentSnapshot()
	if snap == nil {
		ctrl.WriteError(w, r, http.StatusServiceUnavailable, errUnavailable)
		return
	}
	render.JSON(w, r, snap)
}

func (h *Hub) HandleEvents(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet || !strings.EqualFold(r.Header.Get("Upgrade"), "websocket") || r.Header.Get("Sec-WebSocket-Key") == "" {
		ctrl.WriteError(w, r, http.StatusBadRequest, errInvalidRequest)
		return
	}
	m := h.active.Load()
	if m == nil {
		ctrl.WriteError(w, r, http.StatusServiceUnavailable, errUnavailable)
		return
	}
	channel := make(chan *Snapshot, 1)
	h.events.mu.Lock()
	snap := m.currentSnapshot()
	if snap == nil || m.isClosed() {
		h.events.mu.Unlock()
		ctrl.WriteError(w, r, http.StatusServiceUnavailable, errUnavailable)
		return
	}
	h.events.subscribers[channel] = struct{}{}
	channel <- snap
	h.events.mu.Unlock()
	defer func() {
		h.events.mu.Lock()
		delete(h.events.subscribers, channel)
		h.events.mu.Unlock()
	}()
	conn, rw, err := ctrl.UpgradeWebSocket(w, r)
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
				Type     string    `json:"type"`
				Snapshot *Snapshot `json:"snapshot"`
			}{Type: "providers", Snapshot: snapshot})
			if err != nil {
				return
			}
			if err := conn.SetWriteDeadline(time.Now().Add(5 * time.Second)); err != nil {
				return
			}
			if err := ctrl.WriteTextFrame(conn, data); err != nil {
				return
			}
		case <-closed:
			return
		}
	}
}

func (h *Hub) HandleUpdate(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	var body UpdateRequest
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil ||
		(body.Kind != "proxy" && body.Kind != "rule") || body.Name == "" ||
		body.BootID == "" || body.ConfigRevision == 0 {
		ctrl.WriteError(w, r, http.StatusBadRequest, errInvalidRequest)
		return
	}
	m := h.active.Load()
	if m == nil {
		ctrl.WriteError(w, r, http.StatusServiceUnavailable, errUnavailable)
		return
	}
	key := providerKey(body.Kind, body.Name)
	var target updatableProvider
	m.mu.Lock()
	if m.closed || h.active.Load() != m ||
		m.bootID != body.BootID || m.configRevision != body.ConfigRevision {
		m.mu.Unlock()
		ctrl.WriteError(w, r, http.StatusConflict, errStaleConfig)
		return
	}
	if body.Kind == "proxy" {
		item, ok := m.proxyProviders[body.Name]
		if !ok {
			m.mu.Unlock()
			ctrl.WriteError(w, r, http.StatusNotFound, errNotFound)
			return
		}
		if item.VehicleType() != P.HTTP {
			m.mu.Unlock()
			ctrl.WriteError(w, r, http.StatusBadRequest, errNotUpdatable)
			return
		}
		target, ok = item.(updatableProvider)
		if !ok {
			m.mu.Unlock()
			ctrl.WriteError(w, r, http.StatusBadRequest, errNotUpdatable)
			return
		}
	} else {
		item, ok := m.ruleProviders[body.Name]
		if !ok {
			m.mu.Unlock()
			ctrl.WriteError(w, r, http.StatusNotFound, errNotFound)
			return
		}
		if item.VehicleType() != P.HTTP {
			m.mu.Unlock()
			ctrl.WriteError(w, r, http.StatusBadRequest, errNotUpdatable)
			return
		}
		target, ok = item.(updatableProvider)
		if !ok {
			m.mu.Unlock()
			ctrl.WriteError(w, r, http.StatusBadRequest, errNotUpdatable)
			return
		}
	}
	if m.busy[key] {
		m.mu.Unlock()
		ctrl.WriteError(w, r, http.StatusConflict, errBusy)
		return
	}
	m.busy[key] = true
	m.states[key] = opState{phase: "updating", outcome: "none", errCode: ""}
	m.wg.Add(1)
	startSnap := m.rebuildSnapshotLocked()
	m.mu.Unlock()
	defer m.wg.Done()
	h.events.publish(startSnap)

	var changed bool
	var opErr error
	if !m.isClosed() {
		changed, opErr = target.ArkClashUpdate()
	} else {
		opErr = errStaleConfig
	}

	m.mu.Lock()
	delete(m.busy, key)
	if m.closed || h.active.Load() != m ||
		m.bootID != body.BootID || m.configRevision != body.ConfigRevision {
		m.mu.Unlock()
		ctrl.WriteError(w, r, http.StatusConflict, errStaleConfig)
		return
	}
	if opErr != nil {
		code := sanitizeUpdateError(opErr)
		m.states[key] = opState{phase: "idle", outcome: "failed", errCode: code}
		snap := m.rebuildSnapshotLocked()
		m.mu.Unlock()
		h.events.publish(snap)
		status := http.StatusBadGateway
		if code == errTimeout.Error() {
			status = http.StatusGatewayTimeout
		}
		ctrl.WriteError(w, r, status, errors.New(code))
		return
	}
	outcome := "unchanged"
	if changed {
		outcome = "updated"
	}
	m.states[key] = opState{phase: "idle", outcome: outcome, errCode: ""}
	snap := m.rebuildSnapshotLocked()
	m.mu.Unlock()
	h.events.publish(snap)
	render.JSON(w, r, snap)
}

func (h *Hub) HandleReplace(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	var body ReplaceRequest
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil ||
		(body.Kind != "proxy" && body.Kind != "rule") || body.Name == "" ||
		body.BootID == "" || body.ConfigRevision == 0 || body.Candidate == "" {
		ctrl.WriteError(w, r, http.StatusBadRequest, errInvalidRequest)
		return
	}
	m := h.active.Load()
	if m == nil {
		ctrl.WriteError(w, r, http.StatusServiceUnavailable, errUnavailable)
		return
	}
	key := providerKey(body.Kind, body.Name)
	var target replaceableProvider
	var ruleBehavior P.RuleBehavior
	var ruleFormat P.RuleFormat
	var homeDir string
	m.mu.Lock()
	if m.closed || h.active.Load() != m ||
		m.bootID != body.BootID || m.configRevision != body.ConfigRevision {
		m.mu.Unlock()
		ctrl.WriteError(w, r, http.StatusConflict, errStaleConfig)
		return
	}
	homeDir = m.homeDir
	if body.Kind == "proxy" {
		item, ok := m.proxyProviders[body.Name]
		if !ok {
			m.mu.Unlock()
			ctrl.WriteError(w, r, http.StatusNotFound, errNotFound)
			return
		}
		if item.VehicleType() != P.HTTP && item.VehicleType() != P.File {
			m.mu.Unlock()
			ctrl.WriteError(w, r, http.StatusBadRequest, errNotReplaceable)
			return
		}
		target, ok = item.(replaceableProvider)
		if !ok {
			m.mu.Unlock()
			ctrl.WriteError(w, r, http.StatusBadRequest, errNotReplaceable)
			return
		}
	} else {
		item, ok := m.ruleProviders[body.Name]
		if !ok {
			m.mu.Unlock()
			ctrl.WriteError(w, r, http.StatusNotFound, errNotFound)
			return
		}
		if item.VehicleType() != P.HTTP && item.VehicleType() != P.File {
			m.mu.Unlock()
			ctrl.WriteError(w, r, http.StatusBadRequest, errNotReplaceable)
			return
		}
		target, ok = item.(replaceableProvider)
		formatted, hasFormat := item.(ruleFormatProvider)
		if !ok || !hasFormat {
			m.mu.Unlock()
			ctrl.WriteError(w, r, http.StatusBadRequest, errNotReplaceable)
			return
		}
		ruleBehavior = item.Behavior()
		ruleFormat = formatted.ArkClashFormat()
	}
	if err := checkCandidatePath(homeDir, body.Candidate); err != nil {
		m.mu.Unlock()
		ctrl.WriteError(w, r, http.StatusBadRequest, err)
		return
	}
	if m.busy[key] {
		m.mu.Unlock()
		ctrl.WriteError(w, r, http.StatusConflict, errBusy)
		return
	}
	m.busy[key] = true
	m.states[key] = opState{phase: "updating", outcome: "none", errCode: ""}
	m.wg.Add(1)
	startSnap := m.rebuildSnapshotLocked()
	m.mu.Unlock()
	defer m.wg.Done()
	h.events.publish(startSnap)

	var changed bool
	var opErr error
	data, readErr := readCandidate(homeDir, body.Candidate)
	if readErr != nil {
		opErr = readErr
	} else if body.Kind == "rule" {
		opErr = validateRuleCandidate(data, ruleBehavior, ruleFormat)
	}
	if opErr == nil {
		if m.isClosed() {
			opErr = errStaleConfig
		} else {
			changed, opErr = target.ArkClashReplace(data)
			if opErr != nil {
				opErr = errInvalidContent
			}
		}
	}

	m.mu.Lock()
	delete(m.busy, key)
	if m.closed || h.active.Load() != m ||
		m.bootID != body.BootID || m.configRevision != body.ConfigRevision {
		m.mu.Unlock()
		ctrl.WriteError(w, r, http.StatusConflict, errStaleConfig)
		return
	}
	if opErr != nil {
		code := errInvalidContent.Error()
		status := http.StatusUnprocessableEntity
		switch {
		case errors.Is(opErr, errInvalidRequest):
			code = errInvalidRequest.Error()
			status = http.StatusBadRequest
		case errors.Is(opErr, errIO):
			code = errIO.Error()
			status = http.StatusInternalServerError
		}
		m.states[key] = opState{phase: "idle", outcome: "failed", errCode: code}
		snap := m.rebuildSnapshotLocked()
		m.mu.Unlock()
		h.events.publish(snap)
		ctrl.WriteError(w, r, status, errors.New(code))
		return
	}
	outcome := "unchanged"
	if changed {
		outcome = "updated"
	}
	m.states[key] = opState{phase: "idle", outcome: outcome, errCode: ""}
	snap := m.rebuildSnapshotLocked()
	m.mu.Unlock()
	h.events.publish(snap)
	render.JSON(w, r, snap)
}
