// Package ruletunnel 提供按当前 mihomo 规则拨号的 HTTP Transport 与可等待退出上下文。
package ruletunnel

import (
	"context"
	"errors"
	"net"
	"sync"
	"time"

	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/component/ca"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

// RoutePolicy 用于订阅下载等需要按当前转发状态约束直连或校验代次有效性的请求。
type RoutePolicy struct {
	ForceDirect  bool
	StillCurrent func() bool
}

type requestKey struct{}

type requestState struct {
	ctx    context.Context
	cancel context.CancelFunc
	policy *RoutePolicy
	mu     sync.Mutex
	closed bool
	dials  sync.WaitGroup
}

// RequestContext 为单次规则拨号请求绑定独立取消上下文，返回结束并等待所有在途拨号退出的清理函数。
// Transport 会剥离请求取消；值仍保留，因此真实规则解析和拨号使用请求拥有的上下文。
func RequestContext(ctx context.Context, policy *RoutePolicy) (context.Context, func()) {
	ctx, cancel := context.WithCancel(ctx)
	state := &requestState{ctx: ctx, cancel: cancel, policy: policy}
	return context.WithValue(ctx, requestKey{}, state), func() {
		state.mu.Lock()
		state.closed = true
		state.cancel()
		state.mu.Unlock()
		state.dials.Wait()
	}
}

func dialRuleRequest(ctx context.Context, network, address string) (net.Conn, error) {
	state, ok := ctx.Value(requestKey{}).(*requestState)
	if !ok {
		return nil, errors.New("missing_rule_request_context")
	}
	state.mu.Lock()
	if state.closed {
		state.mu.Unlock()
		return nil, context.Canceled
	}
	state.dials.Add(1)
	state.mu.Unlock()
	defer state.dials.Done()
	if err := state.ctx.Err(); err != nil {
		return nil, err
	}
	metadata := &C.Metadata{NetWork: C.TCP, Type: C.INNER, DNSMode: C.DNSNormal, Process: C.MihomoName}
	if err := metadata.SetRemoteAddress(address); err != nil {
		return nil, err
	}
	if policy := state.policy; policy != nil {
		if policy.StillCurrent != nil && !policy.StillCurrent() {
			return nil, errors.New("canceled")
		}
		if policy.ForceDirect {
			metadata.SpecialProxy = "DIRECT"
		}
		return tunnel.DialContextWithTimeout(state.ctx, metadata, 0)
	}
	return tunnel.DialContext(state.ctx, metadata)
}

// NewTransport 每次探测/下载新建连接，避免复用切换节点之前的出口；证书仍使用内核的信任配置。
func NewTransport() (*http.Transport, error) {
	var options ca.Option
	tlsConfig, err := ca.GetTLSConfig(options)
	if err != nil {
		return nil, err
	}
	return &http.Transport{
		DialContext:         dialRuleRequest,
		DisableKeepAlives:   true,
		TLSHandshakeTimeout: 5 * time.Second,
		TLSClientConfig:     tlsConfig,
	}, nil
}
