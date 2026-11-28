// Package probe 提供按当前规则执行出口与服务可用性探测的 HTTP 处理器，不接触核心互斥锁。
package probe

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/VOD-Studio/ArkClash/core/internal/ctrl"
	"github.com/VOD-Studio/ArkClash/core/internal/ruletunnel"
	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
)

const probeRequestLimit = 16 << 10

type RequestBody struct {
	URL         string            `json:"url"`
	Method      string            `json:"method"`
	BodyMode    string            `json:"bodyMode"`
	Headers     map[string]string `json:"headers,omitempty"`
	Body        string            `json:"body,omitempty"`
	NoRedirect  bool              `json:"noRedirect,omitempty"`
	ScanPattern string            `json:"scanPattern,omitempty"`
	Timeout     int               `json:"timeout"`
}

type Response struct {
	Status   int    `json:"status"`
	Body     string `json:"body"`
	URL      string `json:"url"`
	Location string `json:"location"`
	Delay    int64  `json:"delay"`
	BootID   string `json:"bootId"`
	Revision uint64 `json:"revision"`
}

// RuntimeToken 描述一次探测起止之间必须保持一致的运行与路由代次。
type RuntimeToken struct {
	Running       bool
	BootID        string
	Revision      uint64
	RouteToken    any
	RouteRevision uint64
}

type RuntimeObserver func() RuntimeToken

type Handler struct {
	observe RuntimeObserver
	slots   chan struct{}
}

func NewHandler(observe RuntimeObserver) *Handler {
	return &Handler{
		observe: observe,
		slots:   make(chan struct{}, 4),
	}
}

// Slots 返回执行槽通道，供宿主测试检查并发上限与清理情况。
func (h *Handler) Slots() chan struct{} {
	return h.slots
}

func readProbeRequest(r *http.Request) (RequestBody, *regexp.Regexp, error) {
	var options RequestBody
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

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		ctrl.WriteError(w, r, http.StatusMethodNotAllowed, errors.New("invalid_probe_method"))
		return
	}
	options, pattern, err := readProbeRequest(r)
	if err != nil {
		ctrl.WriteError(w, r, http.StatusBadRequest, err)
		return
	}
	start := h.observe()
	if !start.Running {
		ctrl.WriteError(w, r, http.StatusConflict, errors.New("probe_runtime_changed"))
		return
	}
	select {
	case h.slots <- struct{}{}:
		defer func() { <-h.slots }()
	default:
		ctrl.WriteError(w, r, http.StatusTooManyRequests, errors.New("probe_capacity"))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), time.Duration(options.Timeout)*time.Millisecond)
	defer cancel()
	ctx, finishRuleRequest := ruletunnel.RequestContext(ctx, nil)
	defer finishRuleRequest()
	var targetBody io.Reader
	if options.Body != "" {
		targetBody = strings.NewReader(options.Body)
	}
	request, err := http.NewRequestWithContext(ctx, options.Method, options.URL, targetBody)
	if err != nil {
		ctrl.WriteError(w, r, http.StatusBadRequest, errors.New("invalid_probe_url"))
		return
	}
	for name, value := range options.Headers {
		request.Header.Set(name, value)
	}
	transport, err := ruletunnel.NewTransport()
	if err != nil {
		ctrl.WriteError(w, r, http.StatusServiceUnavailable, errors.New("probe_tls_failed"))
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
		body, err = ReadBody(response.Body, options.BodyMode, pattern)
	}
	if r.Context().Err() != nil {
		return
	}
	current := h.observe()
	if !current.Running || current.BootID != start.BootID || current.Revision != start.Revision ||
		current.RouteToken != start.RouteToken || current.RouteRevision != start.RouteRevision {
		ctrl.WriteError(w, r, http.StatusConflict, errors.New("probe_runtime_changed"))
		return
	}
	if ctx.Err() != nil {
		ctrl.WriteError(w, r, http.StatusGatewayTimeout, errors.New("probe_timeout"))
		return
	}
	if err != nil {
		ctrl.WriteError(w, r, http.StatusServiceUnavailable, errors.New("probe_failed"))
		return
	}
	render.JSON(w, r, Response{
		Status: response.StatusCode, Body: body, URL: response.Request.URL.String(),
		Location: response.Header.Get("Location"), Delay: delay, BootID: start.BootID, Revision: start.Revision,
	})
}
