// Package subfetch 提供经内核下载订阅（含 age 解密）与 rule-provider 预下载能力，不接触核心互斥锁。
package subfetch

import (
	"context"
	"errors"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/VOD-Studio/ArkClash/core/internal/ruletunnel"
	"github.com/metacubex/http"
)

// 经内核下载的订阅最大字节数，超过就算失败，防止异常响应占满内存。
const Limit = 64 << 20

type Request struct {
	URL          string            `json:"url"`
	Header       map[string]string `json:"header"`
	Path         string            `json:"path"`      // 响应体写到这里，必须在配置目录下
	TimeoutMs    int               `json:"timeoutMs"` // 整个请求的上限
	MaxBytes     int64             `json:"maxBytes"`
	AgeSecretKey *string           `json:"ageSecretKey"` // 普通订阅传空串，加密订阅传私钥，其他资源省略。
}

type Result struct {
	Status int               `json:"status"`
	Header map[string]string `json:"header,omitempty"` // 键为小写，只保留第一个值
	Error  string            `json:"error,omitempty"`
}

// RuntimeView 为单次下载/预检提供无锁只读的运行状态与代次校验回调。
type RuntimeView struct {
	Running      bool
	HomeDir      string
	Forward      string
	StillCurrent func() bool
}

// CheckProfilePath 校验落盘路径仅允许位于 profiles 或 profile-work 目录下。
func CheckProfilePath(home, path string) error {
	if home == "" {
		return errors.New("invalid_profile_path")
	}
	dir := filepath.Dir(filepath.Clean(path))
	if dir != filepath.Join(home, "profiles") && dir != filepath.Join(home, "profile-work") {
		return errors.New("invalid_profile_path")
	}
	return nil
}

// Fetch 待机和暂停的订阅请求指定 DIRECT，转发时沿用规则。正文直接写入候选文件。
func Fetch(req Request, observe func() RuntimeView) (result Result) {
	view := observe()
	if !view.Running {
		return Result{Error: "core is not running"}
	}
	var policy *ruletunnel.RoutePolicy
	if req.AgeSecretKey != nil {
		switch view.Forward {
		case "stopped", "paused", "running":
			policy = &ruletunnel.RoutePolicy{
				ForceDirect:  view.Forward == "stopped" || view.Forward == "paused",
				StillCurrent: view.StillCurrent,
			}
		default:
			return Result{Error: "busy"}
		}
		defer func() {
			if policy.StillCurrent != nil && !policy.StillCurrent() {
				if result.Status == http.StatusOK {
					_ = os.Remove(req.Path)
				}
				result = Result{Error: "canceled"}
			}
		}()
	}
	if err := CheckProfilePath(view.HomeDir, req.Path); err != nil {
		return Result{Error: err.Error()}
	}
	if req.TimeoutMs <= 0 || req.TimeoutMs > 20000 {
		req.TimeoutMs = 20000
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(req.TimeoutMs)*time.Millisecond)
	defer cancel()
	ctx, finishRuleRequest := ruletunnel.RequestContext(ctx, policy)
	defer finishRuleRequest()

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, req.URL, nil)
	if err != nil {
		return Result{Error: "invalid_url"}
	}
	for key, item := range req.Header {
		request.Header.Set(key, item)
	}
	transport, err := ruletunnel.NewTransport()
	if err != nil {
		return Result{Error: "tls"}
	}
	if policy != nil {
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
		return Result{Error: err.Error()}
	}
	defer resp.Body.Close()

	result = Result{Status: resp.StatusCode, Header: map[string]string{}}
	for k, v := range resp.Header {
		if len(v) > 0 {
			result.Header[strings.ToLower(k)] = v[0]
		}
	}
	if resp.StatusCode != http.StatusOK {
		return result
	}
	limit := int64(Limit)
	if req.MaxBytes > 0 && req.MaxBytes < limit {
		limit = req.MaxBytes
	}
	var body io.Reader = resp.Body
	if req.AgeSecretKey != nil {
		body, err = SubscriptionBody(body, *req.AgeSecretKey, limit)
		if err != nil {
			return Result{Error: err.Error()}
		}
		if body, err = ShareLinkBody(body, limit); err != nil {
			return Result{Error: err.Error()}
		}
	}
	if err := WriteBody(req.Path, body, limit); err != nil {
		return Result{Error: err.Error()}
	}
	return result
}

func WriteBody(path string, body io.Reader, limit int64) error {
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
