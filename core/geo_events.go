package main

import (
	"encoding/json"
	"errors"
	"io"
	"strings"
	"time"

	"github.com/metacubex/http"
)

func getGeoEvents(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet || !strings.EqualFold(r.Header.Get("Upgrade"), "websocket") || r.Header.Get("Sec-WebSocket-Key") == "" {
		writeError(w, r, http.StatusBadRequest, errors.New("geo_invalid_settings"))
		return
	}
	manager := activeGeo.Load()
	if manager == nil {
		writeError(w, r, http.StatusServiceUnavailable, errors.New("geo_canceled"))
		return
	}
	channel := make(chan *geoSnapshot, 1)
	manager.mu.Lock()
	if manager.closed {
		manager.mu.Unlock()
		writeError(w, r, http.StatusServiceUnavailable, errors.New("geo_canceled"))
		return
	}
	// 登记与初始快照同锁，避免订阅空隙遗漏极快完成的任务。
	manager.subscribers[channel] = struct{}{}
	channel <- manager.snapshot.Load()
	manager.mu.Unlock()
	defer func() {
		manager.mu.Lock()
		delete(manager.subscribers, channel)
		manager.mu.Unlock()
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
				Type     string       `json:"type"`
				Snapshot *geoSnapshot `json:"snapshot"`
			}{Type: "geo", Snapshot: snapshot})
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
