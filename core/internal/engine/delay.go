package engine

import (
	"context"
	"errors"
	"net/url"
	"strconv"
	"time"

	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/common/utils"
	C "github.com/metacubex/mihomo/constant"
)

type delayToken struct{}

type DelayRequest struct {
	Profile          string
	ID               string
	Group            string
	URL              string
	TimeoutText      string
	ExpectedBootID   string
	ExpectedRevision string
}

// 调用方持有 e.mu，在替换配置或关闭内核之前同步取消真实测速，不等待网络清理。
func (e *Engine) cancelDelayTestsLocked() {
	for _, cancel := range e.delays.active {
		cancel()
	}
}

func (e *Engine) findDelayProxyLocked(id, groupName string) (C.Proxy, error) {
	if proxy, valid := e.currentProxyMemberLocked(id, groupName); valid {
		return proxy, nil
	}
	return nil, errors.New("delay_node_unavailable")
}

// MeasureDelay 执行单节点测速，强制 8 执行槽限额与配置代次双检查。
// 调用方上下文已取消时返回 (0, 0, ctx.Err())，由 HTTP 层跳过响应写入。
func (e *Engine) MeasureDelay(reqCtx context.Context, req DelayRequest) (uint16, int, error) {
	timeout := 0
	if req.TimeoutText != "" {
		value, err := strconv.Atoi(req.TimeoutText)
		if err != nil || value < 1 || value > 8000 {
			return 0, http.StatusBadRequest, errors.New("invalid_delay_timeout")
		}
		timeout = value
	}
	target, err := url.Parse(req.URL)
	if err != nil || target.Hostname() == "" || (target.Scheme != "https" && target.Scheme != "http") || len(req.URL) > 2048 {
		return 0, http.StatusBadRequest, errors.New("invalid_delay_url")
	}
	select {
	case e.delaySlots <- struct{}{}:
		defer func() { <-e.delaySlots }()
	default:
		return 0, http.StatusTooManyRequests, errors.New("delay_capacity")
	}
	token := new(delayToken)
	var (
		profile  string
		bootID   string
		revision uint64
		valid    bool
		proxy    C.Proxy
		ctx      context.Context
		cancel   context.CancelFunc
	)
	_ = e.withState(func(tx *stateTx) error {
		if timeout == 0 {
			timeout = e.current.General.DelayTimeout
			if timeout == 0 {
				timeout = 8000
			}
		}
		profile = e.current.Profile
		bootID = e.bootID
		revision = e.configRevision
		valid = e.running && profile != "" && req.Profile == profile && req.ExpectedBootID == bootID &&
			req.ExpectedRevision == strconv.FormatUint(revision, 10)
		if valid {
			proxy, err = e.findDelayProxyLocked(req.ID, req.Group)
			if err == nil {
				ctx, cancel = context.WithTimeout(reqCtx, time.Duration(timeout)*time.Millisecond)
				if e.delays.active == nil {
					e.delays.active = make(map[*delayToken]context.CancelFunc)
				}
				e.delays.active[token] = cancel
			}
		}
		return nil
	})
	if !valid {
		return 0, http.StatusConflict, errors.New("delay_profile_changed")
	}
	if err != nil {
		return 0, http.StatusConflict, err
	}
	defer func() {
		cancel()
		_ = e.withState(func(tx *stateTx) error {
			delete(e.delays.active, token)
			return nil
		})
	}()
	expected, _ := utils.NewUnsignedRanges[uint16]("")
	delay, err := proxy.URLTest(ctx, target.String(), expected)
	if reqCtx.Err() != nil {
		return 0, 0, reqCtx.Err()
	}
	_ = e.withState(func(tx *stateTx) error {
		member, present := e.currentProxyMemberLocked(req.ID, req.Group)
		valid = e.running && profile != "" && e.current.Profile == profile && e.bootID == bootID && e.configRevision == revision &&
			present && member == proxy
		return nil
	})
	if !valid {
		return 0, http.StatusConflict, errors.New("delay_profile_changed")
	}
	if ctx.Err() != nil {
		return 0, http.StatusGatewayTimeout, errors.New("delay_timeout")
	}
	if err != nil || delay == 0 {
		return 0, http.StatusServiceUnavailable, errors.New("delay_failed")
	}
	return delay, http.StatusOK, nil
}
