package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
)

type geoResourceStatus struct {
	ID            geoResourceID `json:"id"`
	FileName      string        `json:"fileName"`
	Exists        bool          `json:"exists"`
	Size          int64         `json:"size"`
	ModifiedAt    int64         `json:"modifiedAt"`
	Phase         string        `json:"phase"`
	OperationID   string        `json:"operationId"`
	Outcome       string        `json:"outcome"`
	Error         string        `json:"error"`
	ReceivedBytes int64         `json:"receivedBytes,omitempty"`
	TotalBytes    int64         `json:"totalBytes,omitempty"`
}

type geoSnapshot struct {
	BootID           string              `json:"bootId"`
	Revision         uint64              `json:"revision"`
	SettingsRevision string              `json:"settingsRevision"`
	Items            []geoResourceStatus `json:"items"`
}

type geoTimer interface{ Stop() bool }

type geoJob struct {
	id          geoResourceID
	bootID      string
	source      string
	path        string
	operationID string
	automatic   bool
	ctx         context.Context
	cancel      context.CancelFunc
}

type geoManager struct {
	mu           sync.Mutex
	home         string
	bootID       string
	settings     geoSettings
	items        []geoResourceStatus
	paths        map[geoResourceID]string
	metadata     map[geoResourceID]geoMetadata
	metadataOK   map[geoResourceID]bool
	jobs         map[geoResourceID]*geoJob
	queue        []*geoJob
	active       *geoJob
	sequence     uint64
	revision     uint64
	closed       bool
	ctx          context.Context
	cancel       context.CancelFunc
	wake         chan struct{}
	done         chan struct{}
	snapshot     atomic.Pointer[geoSnapshot]
	subscribers  map[chan *geoSnapshot]struct{}
	now          func() time.Time
	afterFunc    func(time.Duration, func()) geoTimer
	timer        geoTimer
	timerVersion uint64
	startupFloor time.Time
}

func newGeoManager(home, bootID string, settings geoSettings) (*geoManager, error) {
	return newGeoManagerWithClock(home, bootID, settings, time.Now, func(delay time.Duration, callback func()) geoTimer {
		return time.AfterFunc(delay, callback)
	})
}

func newGeoManagerWithClock(home, bootID string, settings geoSettings, now func() time.Time, afterFunc func(time.Duration, func()) geoTimer) (*geoManager, error) {
	if err := validateGeoSettings(settings); err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	manager := &geoManager{
		home: home, bootID: bootID, settings: settings, paths: make(map[geoResourceID]string),
		metadata: make(map[geoResourceID]geoMetadata), metadataOK: make(map[geoResourceID]bool),
		jobs: make(map[geoResourceID]*geoJob), subscribers: make(map[chan *geoSnapshot]struct{}),
		ctx: ctx, cancel: cancel, wake: make(chan struct{}, 1), done: make(chan struct{}),
		now: now, afterFunc: afterFunc, startupFloor: now().Add(10 * time.Second),
	}
	manager.cleanTemps()
	for _, id := range geoIDs {
		item := geoResourceStatus{ID: id, Phase: "idle", Outcome: "none"}
		path, err := geoPath(home, id)
		item.FileName = filepath.Base(path)
		if err != nil {
			item.Error = "geo_io"
		} else {
			manager.paths[id] = path
			if err := statGeoResource(path, &item); err != nil {
				item.Error = "geo_io"
			}
		}
		metadata, err := readGeoMetadata(home, id)
		manager.metadata[id] = metadata
		manager.metadataOK[id] = err == nil
		if err != nil {
			item.Error = err.Error()
		}
		manager.items = append(manager.items, item)
	}
	manager.mu.Lock()
	manager.publishLocked()
	manager.scheduleLocked()
	manager.mu.Unlock()
	go manager.run()
	return manager, nil
}

func (m *geoManager) cleanTemps() {
	entries, err := os.ReadDir(m.home)
	if err != nil {
		return
	}
	for _, entry := range entries {
		if !entry.Type().IsRegular() || !strings.HasSuffix(entry.Name(), ".tmp") {
			continue
		}
		for _, id := range geoIDs {
			if strings.HasPrefix(entry.Name(), "arkclash-geo-"+string(id)+"-") {
				_ = os.Remove(filepath.Join(m.home, entry.Name()))
				break
			}
		}
	}
}

func statGeoResource(path string, item *geoResourceStatus) error {
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		item.Exists, item.Size, item.ModifiedAt = false, 0, 0
		return nil
	}
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		item.Exists, item.Size, item.ModifiedAt = false, 0, 0
		return nil
	}
	item.Exists, item.Size, item.ModifiedAt = true, info.Size(), info.ModTime().UnixMilli()
	return nil
}

// 发布后快照不再修改；慢连接只保留最新完整状态。
func (m *geoManager) publishLocked() {
	m.revision++
	snapshot := &geoSnapshot{BootID: m.bootID, Revision: m.revision, SettingsRevision: m.settings.Revision,
		Items: append([]geoResourceStatus(nil), m.items...)}
	m.snapshot.Store(snapshot)
	for channel := range m.subscribers {
		select {
		case <-channel:
		default:
		}
		channel <- snapshot
	}
}

func (m *geoManager) enqueue(ids []geoResourceID, automatic bool) (*geoSnapshot, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed {
		return nil, errors.New("geo_canceled")
	}
	if len(ids) < 1 || len(ids) > 4 {
		return nil, errors.New("geo_invalid_settings")
	}
	for _, id := range ids {
		if geoIndex(id) < 0 {
			return nil, errors.New("geo_invalid_settings")
		}
	}
	if m.enqueueItemsLocked(ids, automatic) {
		m.publishLocked()
	}
	m.scheduleLocked()
	return m.snapshot.Load(), nil
}

func (m *geoManager) enqueueForBoot(expectedBootID string, ids []geoResourceID) (*geoSnapshot, int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed {
		return nil, http.StatusServiceUnavailable, errors.New("geo_canceled")
	}
	if expectedBootID != m.bootID {
		return nil, http.StatusConflict, errors.New("geo_stale_boot")
	}
	if len(ids) < 1 || len(ids) > 4 {
		return nil, http.StatusBadRequest, errors.New("geo_invalid_settings")
	}
	for _, id := range ids {
		if geoIndex(id) < 0 {
			return nil, http.StatusBadRequest, errors.New("geo_invalid_settings")
		}
	}
	if m.enqueueItemsLocked(ids, false) {
		m.publishLocked()
	}
	m.scheduleLocked()
	return m.snapshot.Load(), http.StatusAccepted, nil
}

func (m *geoManager) enqueueItemsLocked(ids []geoResourceID, automatic bool) bool {
	changed := false
	for _, id := range ids {
		if job := m.jobs[id]; job != nil {
			// 手动接管自动任务仍复用操作号，关闭自动更新不取消它。
			if !automatic {
				job.automatic = false
			}
			continue
		}
		if automatic && (!m.metadataOK[id] || m.paths[id] == "") {
			continue
		}
		m.sequence++
		ctx, cancel := context.WithCancel(m.ctx)
		job := &geoJob{id: id, bootID: m.bootID, source: m.settings.source(id), path: m.paths[id],
			operationID: fmt.Sprintf("%s-%x", m.bootID, m.sequence), automatic: automatic, ctx: ctx, cancel: cancel}
		m.jobs[id] = job
		m.queue = append(m.queue, job)
		item := &m.items[geoIndex(id)]
		item.Phase, item.OperationID, item.Outcome, item.Error = "queued", job.operationID, "none", ""
		item.ReceivedBytes, item.TotalBytes = 0, 0
		changed = true
	}
	if changed {
		select {
		case m.wake <- struct{}{}:
		default:
		}
	}
	return changed
}

func (m *geoManager) applySettings(settings geoSettings) error {
	if err := validateGeoSettings(settings); err != nil {
		return err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed {
		return errors.New("geo_canceled")
	}
	m.settings = settings
	kept := m.queue[:0]
	for _, job := range m.queue {
		if job.source != settings.source(job.id) || (job.automatic && !settings.AutoUpdate) {
			job.cancel()
			delete(m.jobs, job.id)
			item := &m.items[geoIndex(job.id)]
			item.Phase, item.Outcome, item.Error = "idle", "canceled", "geo_canceled"
		} else {
			kept = append(kept, job)
		}
	}
	m.queue = kept
	if job := m.active; job != nil && (job.source != settings.source(job.id) || (job.automatic && !settings.AutoUpdate)) {
		job.cancel()
	}
	m.publishLocked()
	m.scheduleLocked()
	return nil
}

func (m *geoManager) dueAtLocked(id geoResourceID) time.Time {
	base := m.items[geoIndex(id)].ModifiedAt
	if attempt := m.metadata[id].LastAttemptAt; attempt > base {
		base = attempt
	}
	due := time.UnixMilli(base).Add(time.Duration(m.settings.IntervalHours) * time.Hour)
	if due.Before(m.startupFloor) {
		due = m.startupFloor
	}
	return due
}

// 唯一的一次性定时器只瞄准下一项到期时间，不做间隔轮询。
func (m *geoManager) scheduleLocked() {
	if m.timer != nil {
		m.timer.Stop()
		m.timer = nil
	}
	m.timerVersion++
	if m.closed || !m.settings.AutoUpdate {
		return
	}
	var next time.Time
	for _, id := range geoIDs {
		if m.jobs[id] != nil || !m.metadataOK[id] || m.paths[id] == "" {
			continue
		}
		due := m.dueAtLocked(id)
		if next.IsZero() || due.Before(next) {
			next = due
		}
	}
	if next.IsZero() {
		return
	}
	delay := next.Sub(m.now())
	if delay < 0 {
		delay = 0
	}
	version := m.timerVersion
	m.timer = m.afterFunc(delay, func() {
		m.mu.Lock()
		defer m.mu.Unlock()
		if m.closed || !m.settings.AutoUpdate || version != m.timerVersion {
			return
		}
		m.timer = nil
		now := m.now()
		var ids []geoResourceID
		for _, id := range geoIDs {
			if m.jobs[id] == nil && m.metadataOK[id] && m.paths[id] != "" && !m.dueAtLocked(id).After(now) {
				ids = append(ids, id)
			}
		}
		if m.enqueueItemsLocked(ids, true) {
			m.publishLocked()
		}
		m.scheduleLocked()
	})
}

func (m *geoManager) close() {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed {
		return
	}
	m.closed = true
	m.cancel()
	if m.timer != nil {
		m.timer.Stop()
		m.timer = nil
	}
	m.timerVersion++
	for _, job := range m.jobs {
		job.cancel()
		item := &m.items[geoIndex(job.id)]
		item.Phase, item.Outcome, item.Error = "idle", "canceled", "geo_canceled"
	}
	m.queue = nil
	m.publishLocked()
	for channel := range m.subscribers {
		close(channel)
		delete(m.subscribers, channel)
	}
}

func (m *geoManager) wait() { <-m.done }

func (m *geoManager) run() {
	defer close(m.done)
	for {
		m.mu.Lock()
		if m.closed {
			m.mu.Unlock()
			return
		}
		if len(m.queue) == 0 {
			m.mu.Unlock()
			select {
			case <-m.wake:
			case <-m.ctx.Done():
				return
			}
			continue
		}
		job := m.queue[0]
		m.queue[0] = nil
		m.queue = m.queue[1:]
		m.active = job
		m.mu.Unlock()
		outcome, err := m.update(job)
		job.cancel()
		m.mu.Lock()
		m.active = nil
		delete(m.jobs, job.id)
		if !m.closed {
			item := &m.items[geoIndex(job.id)]
			item.Phase, item.Outcome, item.Error = "idle", outcome, ""
			if err != nil {
				item.Error = err.Error()
			}
			m.publishLocked()
			m.scheduleLocked()
		}
		m.mu.Unlock()
	}
}

func readGeoRequest(r *http.Request, value any, fields ...string) error {
	data, err := io.ReadAll(io.LimitReader(r.Body, geoJSONLimit+1))
	if err != nil || len(data) > geoJSONLimit || !geoRequiredFields(data, fields...) || decodeGeoJSON(data, value) != nil {
		return errors.New("geo_invalid_settings")
	}
	return nil
}

func getGeo(w http.ResponseWriter, r *http.Request) {
	manager := eng.geo.Load()
	if manager == nil || manager.ctx.Err() != nil {
		writeError(w, r, http.StatusServiceUnavailable, errors.New("geo_canceled"))
		return
	}
	render.JSON(w, r, manager.snapshot.Load())
}

func postGeoSettings(w http.ResponseWriter, r *http.Request) {
	var body struct {
		ExpectedBootID string `json:"expectedBootId"`
		Revision       string `json:"revision"`
	}
	if err := readGeoRequest(r, &body, "expectedBootId", "revision"); err != nil || body.ExpectedBootID == "" || body.Revision == "" {
		writeError(w, r, http.StatusBadRequest, errors.New("geo_invalid_settings"))
		return
	}
	snapshot, status, err := eng.ApplyGeoSettings(body.ExpectedBootID, body.Revision)
	if err != nil {
		writeError(w, r, status, err)
		return
	}
	render.JSON(w, r, snapshot)
}

func postGeoUpdate(w http.ResponseWriter, r *http.Request) {
	var body struct {
		ExpectedBootID string          `json:"expectedBootId"`
		IDs            []geoResourceID `json:"ids"`
	}
	if err := readGeoRequest(r, &body, "expectedBootId", "ids"); err != nil || body.ExpectedBootID == "" || len(body.IDs) < 1 || len(body.IDs) > 4 {
		writeError(w, r, http.StatusBadRequest, errors.New("geo_invalid_settings"))
		return
	}
	for _, id := range body.IDs {
		if geoIndex(id) < 0 {
			writeError(w, r, http.StatusBadRequest, errors.New("geo_invalid_settings"))
			return
		}
	}
	manager := eng.geo.Load()
	if manager == nil {
		writeError(w, r, http.StatusServiceUnavailable, errors.New("geo_canceled"))
		return
	}
	snapshot, status, err := manager.enqueueForBoot(body.ExpectedBootID, body.IDs)
	if err != nil {
		writeError(w, r, status, err)
		return
	}
	render.Status(r, status)
	render.JSON(w, r, snapshot)
}
