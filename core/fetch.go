package main

import (
	"context"
	"errors"
	"io"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/metacubex/http"
)

// 经内核下载的订阅最大字节数，超过就算失败，防止异常响应占满内存。
const fetchLimit = 64 << 20

type fetchRequest struct {
	URL          string            `json:"url"`
	Header       map[string]string `json:"header"`
	Path         string            `json:"path"`      // 响应体写到这里，必须在配置目录下
	TimeoutMs    int               `json:"timeoutMs"` // 整个请求的上限
	MaxBytes     int64             `json:"maxBytes"`
	AgeSecretKey *string           `json:"ageSecretKey"` // 普通订阅传空串，加密订阅传私钥，其他资源省略。
}

type fetchResult struct {
	Status int               `json:"status"`
	Header map[string]string `json:"header,omitempty"` // 键为小写，只保留第一个值
	Error  string            `json:"error,omitempty"`
}

// 待机和暂停的订阅请求指定 DIRECT，转发时沿用规则。正文直接写入候选文件。
func fetch(req fetchRequest) (result fetchResult) {
	status := runtimeSnapshot.Load()
	if status == nil || !status.Running {
		return fetchResult{Error: "core is not running"}
	}
	var subscription *statusResponse
	if req.AgeSecretKey != nil {
		switch status.Forward {
		case "stopped", "paused", "running":
			subscription = status
		default:
			return fetchResult{Error: "busy"}
		}
		defer func() {
			if !subscription.subscriptionRouteCurrent() {
				if result.Status == http.StatusOK {
					_ = os.Remove(req.Path)
				}
				result = fetchResult{Error: "canceled"}
			}
		}()
	}
	if err := checkProfilePath(status.homeDir, req.Path); err != nil {
		return fetchResult{Error: err.Error()}
	}
	if req.TimeoutMs <= 0 || req.TimeoutMs > 20000 {
		req.TimeoutMs = 20000
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(req.TimeoutMs)*time.Millisecond)
	defer cancel()
	ctx, finishRuleRequest := ruleRequestContext(ctx, subscription)
	defer finishRuleRequest()

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, req.URL, nil)
	if err != nil {
		return fetchResult{Error: "invalid_url"}
	}
	for key, item := range req.Header {
		request.Header.Set(key, item)
	}
	transport, err := newRuleTransport()
	if err != nil {
		return fetchResult{Error: "tls"}
	}
	if subscription != nil {
		// 订阅的连接、TLS 握手和响应体共用请求期限。
		transport.TLSHandshakeTimeout = 0
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport}
	resp, err := client.Do(request)
	if err != nil {
		// url.Error 会带上完整链接，订阅链接不能出现在错误信息里（AGENTS.md「安全」）。
		var urlErr *url.Error
		if errors.As(err, &urlErr) {
			err = urlErr.Err
		}
		return fetchResult{Error: err.Error()}
	}
	defer resp.Body.Close()

	result = fetchResult{Status: resp.StatusCode, Header: map[string]string{}}
	for k, v := range resp.Header {
		if len(v) > 0 {
			result.Header[strings.ToLower(k)] = v[0]
		}
	}
	if resp.StatusCode != http.StatusOK {
		return result
	}
	limit := int64(fetchLimit)
	if req.MaxBytes > 0 && req.MaxBytes < limit {
		limit = req.MaxBytes
	}
	var body io.Reader = resp.Body
	if req.AgeSecretKey != nil {
		body, err = subscriptionBody(body, *req.AgeSecretKey, limit)
		if err != nil {
			return fetchResult{Error: err.Error()}
		}
	}
	if err := writeBody(req.Path, body, limit); err != nil {
		return fetchResult{Error: err.Error()}
	}
	return result
}

func writeBody(path string, body io.Reader, limit int64) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	n, err := io.Copy(f, io.LimitReader(body, limit+1))
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	if err == nil && n > limit {
		err = errors.New("response too large")
	}
	if err != nil {
		_ = os.Remove(path)
	}
	return err
}
