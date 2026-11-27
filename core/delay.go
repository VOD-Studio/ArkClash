package main

import (
	"context"
	"errors"
	"net/url"
	"strconv"
	"time"

	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/common/utils"
	C "github.com/metacubex/mihomo/constant"
)

var delaySlots = make(chan struct{}, 8)

// 调用方持有 eng.mu，在替换配置或关闭内核之前同步取消真实测速，不等待网络清理。
func cancelDelayTests() {
	for _, cancel := range eng.delays.active {
		cancel()
	}
}

func findDelayProxy(id, groupName string) (C.Proxy, error) {
	if proxy, valid := currentProxyMember(id, groupName); valid {
		return proxy, nil
	}
	return nil, errors.New("delay_node_unavailable")
}

func getDelay(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query()
	timeout := 0
	if text := query.Get("timeout"); text != "" {
		value, err := strconv.Atoi(text)
		if err != nil || value < 1 || value > 8000 {
			writeError(w, r, http.StatusBadRequest, errors.New("invalid_delay_timeout"))
			return
		}
		timeout = value
	}
	target, err := url.Parse(query.Get("url"))
	if err != nil || target.Hostname() == "" || (target.Scheme != "https" && target.Scheme != "http") || len(query.Get("url")) > 2048 {
		writeError(w, r, http.StatusBadRequest, errors.New("invalid_delay_url"))
		return
	}
	select {
	case delaySlots <- struct{}{}:
		defer func() { <-delaySlots }()
	default:
		writeError(w, r, http.StatusTooManyRequests, errors.New("delay_capacity"))
		return
	}
	var (
		profile  string
		bootID   string
		revision uint64
		valid    bool
		proxy    C.Proxy
		ctx      context.Context
		cancel   context.CancelFunc
	)
	_ = eng.withState(func(tx *stateTx) error {
		if timeout == 0 {
			timeout = eng.current.General.DelayTimeout
			if timeout == 0 {
				timeout = 8000
			}
		}
		profile = eng.current.Profile
		bootID = eng.bootID
		revision = eng.configRevision
		valid = eng.running && profile != "" && query.Get("profile") == profile && query.Get("expectedBootId") == bootID &&
			query.Get("expectedRevision") == strconv.FormatUint(revision, 10)
		if valid {
			proxy, err = findDelayProxy(query.Get("id"), query.Get("group"))
			if err == nil {
				ctx, cancel = context.WithTimeout(r.Context(), time.Duration(timeout)*time.Millisecond)
				if eng.delays.active == nil {
					eng.delays.active = make(map[*http.Request]context.CancelFunc)
				}
				eng.delays.active[r] = cancel
			}
		}
		return nil
	})
	if !valid {
		writeError(w, r, http.StatusConflict, errors.New("delay_profile_changed"))
		return
	}
	if err != nil {
		writeError(w, r, http.StatusConflict, err)
		return
	}
	defer func() {
		cancel()
		_ = eng.withState(func(tx *stateTx) error {
			delete(eng.delays.active, r)
			return nil
		})
	}()
	expected, _ := utils.NewUnsignedRanges[uint16]("")
	delay, err := proxy.URLTest(ctx, target.String(), expected)
	if r.Context().Err() != nil {
		return
	}
	_ = eng.withState(func(tx *stateTx) error {
		member, present := currentProxyMember(query.Get("id"), query.Get("group"))
		valid = eng.running && profile != "" && eng.current.Profile == profile && eng.bootID == bootID && eng.configRevision == revision &&
			present && member == proxy
		return nil
	})
	if !valid {
		writeError(w, r, http.StatusConflict, errors.New("delay_profile_changed"))
		return
	}
	if ctx.Err() != nil {
		writeError(w, r, http.StatusGatewayTimeout, errors.New("delay_timeout"))
		return
	}
	if err != nil || delay == 0 {
		writeError(w, r, http.StatusServiceUnavailable, errors.New("delay_failed"))
		return
	}
	render.JSON(w, r, struct {
		Delay uint16 `json:"delay"`
	}{Delay: delay})
}
