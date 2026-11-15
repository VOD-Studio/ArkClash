package main

import (
	"context"
	"errors"
	"io"
	"net"
	"net/url"
	"strconv"
	"sync"
	"time"

	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/component/ca"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

const probeLimit = 64 << 10

var probeSlots = make(chan struct{}, 4)

type ruleRequestKey struct{}

type ruleRequestState struct {
	ctx    context.Context
	cancel context.CancelFunc
	mu     sync.Mutex
	closed bool
	dials  sync.WaitGroup
}

// Transport 会剥离请求取消；值仍保留，因此真实规则解析和拨号使用请求拥有的上下文。
func ruleRequestContext(ctx context.Context) (context.Context, func()) {
	ctx, cancel := context.WithCancel(ctx)
	state := &ruleRequestState{ctx: ctx, cancel: cancel}
	return context.WithValue(ctx, ruleRequestKey{}, state), func() {
		state.mu.Lock()
		state.closed = true
		state.cancel()
		state.mu.Unlock()
		state.dials.Wait()
	}
}

func dialRuleRequest(ctx context.Context, network, address string) (net.Conn, error) {
	state, ok := ctx.Value(ruleRequestKey{}).(*ruleRequestState)
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
	return tunnel.DialContext(state.ctx, metadata)
}

// 每次探测新建连接，避免复用切换节点之前的出口；证书仍使用内核的信任配置。
func newRuleTransport() (*http.Transport, error) {
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

func getProbe(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query()
	target, err := url.Parse(query.Get("url"))
	if err != nil || target.Hostname() == "" || target.User != nil || len(query.Get("url")) > 2048 ||
		(target.Scheme != "http" && target.Scheme != "https") {
		writeError(w, r, http.StatusBadRequest, errors.New("invalid_probe_url"))
		return
	}
	method := query.Get("method")
	if method == "" {
		method = http.MethodGet
	}
	if method != http.MethodGet && method != http.MethodHead {
		writeError(w, r, http.StatusBadRequest, errors.New("invalid_probe_method"))
		return
	}
	timeout := 5000
	if text := query.Get("timeout"); text != "" {
		value, err := strconv.Atoi(text)
		if err != nil || value < 1 || value > 5000 {
			writeError(w, r, http.StatusBadRequest, errors.New("invalid_probe_timeout"))
			return
		}
		timeout = value
	}
	snapshot := runtimeSnapshot.Load()
	routes := runtimeRoutes.Load()
	var routeRevision uint64
	if routes != nil {
		routeRevision = routes.changes.Load()
	}
	if snapshot == nil || !snapshot.Running {
		writeError(w, r, http.StatusConflict, errors.New("probe_runtime_changed"))
		return
	}
	select {
	case probeSlots <- struct{}{}:
		defer func() { <-probeSlots }()
	default:
		writeError(w, r, http.StatusTooManyRequests, errors.New("probe_capacity"))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), time.Duration(timeout)*time.Millisecond)
	defer cancel()
	ctx, finishRuleRequest := ruleRequestContext(ctx)
	defer finishRuleRequest()
	request, err := http.NewRequestWithContext(ctx, method, target.String(), nil)
	if err != nil {
		writeError(w, r, http.StatusBadRequest, errors.New("invalid_probe_url"))
		return
	}
	transport, err := newRuleTransport()
	if err != nil {
		writeError(w, r, http.StatusServiceUnavailable, errors.New("probe_tls_failed"))
		return
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport}
	response, err := client.Do(request)
	var body []byte
	if response != nil {
		defer response.Body.Close()
	}
	if err == nil && method != http.MethodHead {
		body, err = io.ReadAll(io.LimitReader(response.Body, probeLimit+1))
	}
	if r.Context().Err() != nil {
		return
	}
	current := runtimeSnapshot.Load()
	if current == nil || !current.Running || current.BootID != snapshot.BootID || current.Revision != snapshot.Revision ||
		runtimeRoutes.Load() != routes || (routes != nil && routes.changes.Load() != routeRevision) {
		writeError(w, r, http.StatusConflict, errors.New("probe_runtime_changed"))
		return
	}
	if ctx.Err() != nil {
		writeError(w, r, http.StatusGatewayTimeout, errors.New("probe_timeout"))
		return
	}
	if err != nil || len(body) > probeLimit {
		writeError(w, r, http.StatusServiceUnavailable, errors.New("probe_failed"))
		return
	}
	render.JSON(w, r, struct {
		Status   int    `json:"status"`
		Body     string `json:"body"`
		BootID   string `json:"bootId"`
		Revision uint64 `json:"revision"`
	}{Status: response.StatusCode, Body: string(body), BootID: snapshot.BootID, Revision: snapshot.Revision})
}
