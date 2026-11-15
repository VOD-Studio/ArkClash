package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/component/ca"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

const probeRequestLimit = 16 << 10

type probeRequestBody struct {
	URL         string            `json:"url"`
	Method      string            `json:"method"`
	BodyMode    string            `json:"bodyMode"`
	Headers     map[string]string `json:"headers,omitempty"`
	Body        string            `json:"body,omitempty"`
	NoRedirect  bool              `json:"noRedirect,omitempty"`
	ScanPattern string            `json:"scanPattern,omitempty"`
	Timeout     int               `json:"timeout"`
}

type probeResponse struct {
	Status   int    `json:"status"`
	Body     string `json:"body"`
	URL      string `json:"url"`
	Location string `json:"location"`
	Delay    int64  `json:"delay"`
	BootID   string `json:"bootId"`
	Revision uint64 `json:"revision"`
}

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

func readProbeRequest(r *http.Request) (probeRequestBody, *regexp.Regexp, error) {
	var options probeRequestBody
	body, err := io.ReadAll(io.LimitReader(r.Body, probeRequestLimit+1))
	if err != nil || len(body) > probeRequestLimit {
		return options, nil, errors.New("invalid_probe_request")
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&options); err != nil {
		return options, nil, errors.New("invalid_probe_request")
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return options, nil, errors.New("invalid_probe_request")
	}
	target, err := url.Parse(options.URL)
	if err != nil || target.Hostname() == "" || target.User != nil || len(options.URL) > 2048 ||
		(target.Scheme != "http" && target.Scheme != "https") {
		return options, nil, errors.New("invalid_probe_url")
	}
	if options.Method != http.MethodGet && options.Method != http.MethodHead && options.Method != http.MethodPost {
		return options, nil, errors.New("invalid_probe_method")
	}
	if options.Timeout < 1 || options.Timeout > 10000 {
		return options, nil, errors.New("invalid_probe_timeout")
	}
	if len(options.Body) > 8192 {
		return options, nil, errors.New("invalid_probe_body")
	}
	for name, value := range options.Headers {
		switch http.CanonicalHeaderKey(name) {
		case "User-Agent", "Accept", "Content-Type", "Authorization":
		default:
			return options, nil, errors.New("invalid_probe_headers")
		}
		for i := range len(value) {
			if (value[i] < ' ' && value[i] != '\t') || value[i] == 127 {
				return options, nil, errors.New("invalid_probe_headers")
			}
		}
	}
	switch options.BodyMode {
	case "none", "small", "html", "json":
		if options.ScanPattern != "" {
			return options, nil, errors.New("invalid_probe_scan_pattern")
		}
		return options, nil, nil
	case "scan":
		if options.ScanPattern == "" || len(options.ScanPattern) > 512 {
			return options, nil, errors.New("invalid_probe_scan_pattern")
		}
		pattern, err := regexp.Compile(options.ScanPattern)
		if err != nil {
			return options, nil, errors.New("invalid_probe_scan_pattern")
		}
		return options, pattern, nil
	default:
		return options, nil, errors.New("invalid_probe_body_mode")
	}
}

func probeURLPort(target *url.URL) string {
	if port := target.Port(); port != "" {
		return port
	}
	if target.Scheme == "https" {
		return "443"
	}
	return "80"
}

func sameProbeOrigin(a, b *url.URL) bool {
	return strings.EqualFold(a.Scheme, b.Scheme) && strings.EqualFold(a.Hostname(), b.Hostname()) && probeURLPort(a) == probeURLPort(b)
}

func postProbe(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, r, http.StatusMethodNotAllowed, errors.New("invalid_probe_method"))
		return
	}
	options, pattern, err := readProbeRequest(r)
	if err != nil {
		writeError(w, r, http.StatusBadRequest, err)
		return
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
	ctx, cancel := context.WithTimeout(r.Context(), time.Duration(options.Timeout)*time.Millisecond)
	defer cancel()
	ctx, finishRuleRequest := ruleRequestContext(ctx)
	defer finishRuleRequest()
	var targetBody io.Reader
	if options.Body != "" {
		targetBody = strings.NewReader(options.Body)
	}
	request, err := http.NewRequestWithContext(ctx, options.Method, options.URL, targetBody)
	if err != nil {
		writeError(w, r, http.StatusBadRequest, errors.New("invalid_probe_url"))
		return
	}
	for name, value := range options.Headers {
		request.Header.Set(name, value)
	}
	transport, err := newRuleTransport()
	if err != nil {
		writeError(w, r, http.StatusServiceUnavailable, errors.New("probe_tls_failed"))
		return
	}
	defer transport.CloseIdleConnections()
	forwardAuthorization := true
	client := &http.Client{Transport: transport, CheckRedirect: func(next *http.Request, via []*http.Request) error {
		if options.NoRedirect {
			return http.ErrUseLastResponse
		}
		if len(via) >= 10 {
			return errors.New("probe_redirect_limit")
		}
		if next.URL.User != nil || next.URL.Hostname() == "" || len(next.URL.String()) > 2048 ||
			(next.URL.Scheme != "http" && next.URL.Scheme != "https") {
			return errors.New("invalid_probe_redirect")
		}
		if !sameProbeOrigin(via[len(via)-1].URL, next.URL) {
			// POST 正文也可能携带临时令牌，不能在跨源的 307/308 中重放。
			if next.Body != nil && next.Body != http.NoBody {
				return http.ErrUseLastResponse
			}
			forwardAuthorization = false
		}
		// http.Client 会从首个请求重新复制头；跨源后所有后续跳转都必须保持移除。
		if !forwardAuthorization {
			next.Header.Del("Authorization")
		}
		return nil
	}}
	started := time.Now()
	response, err := client.Do(request)
	delay := time.Since(started).Milliseconds()
	var body string
	if response != nil {
		defer response.Body.Close()
	}
	if err == nil && options.Method != http.MethodHead {
		body, err = readProbeBody(response.Body, options.BodyMode, pattern)
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
	if err != nil {
		writeError(w, r, http.StatusServiceUnavailable, errors.New("probe_failed"))
		return
	}
	render.JSON(w, r, probeResponse{
		Status: response.StatusCode, Body: body, URL: response.Request.URL.String(),
		Location: response.Header.Get("Location"), Delay: delay, BootID: snapshot.BootID, Revision: snapshot.Revision,
	})
}
