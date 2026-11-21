package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/component/geodata"
	"github.com/metacubex/mihomo/component/geodata/router"
	"github.com/metacubex/mihomo/component/mmdb"
	"github.com/oschwald/maxminddb-golang"
	"google.golang.org/protobuf/proto"
)

const geoDownloadLimit = 64 << 20

var geoDownloadTimeout = 60 * time.Second

type geoContextReader struct {
	ctx    context.Context
	reader io.Reader
	onRead func(int)
}

func (reader geoContextReader) Read(buffer []byte) (int, error) {
	if err := reader.ctx.Err(); err != nil {
		return 0, err
	}
	n, err := reader.reader.Read(buffer)
	if reader.onRead != nil && n > 0 {
		reader.onRead(n)
	}
	return n, err
}

func (m *geoManager) reportDownload(job *geoJob, received, total int64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.jobValidLocked(job) {
		return
	}
	item := &m.items[geoIndex(job.id)]
	if item.ReceivedBytes != received || item.TotalBytes != total {
		item.ReceivedBytes, item.TotalBytes = received, total
		m.publishLocked()
	}
}

func geoContextError(ctx context.Context) error {
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return errors.New("geo_timeout")
	}
	return errors.New("geo_canceled")
}

func (m *geoManager) jobValidLocked(job *geoJob) bool {
	return !m.closed && job.bootID == m.bootID && job.ctx.Err() == nil && m.jobs[job.id] == job && m.settings.source(job.id) == job.source
}

// 开始尝试先落盘时间戳；下载失败也不能令调度器立即再次唤醒。
func (m *geoManager) beginAttempt(job *geoJob) error {
	mu.Lock()
	defer mu.Unlock()
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.jobValidLocked(job) {
		return errors.New("geo_canceled")
	}
	item := &m.items[geoIndex(job.id)]
	item.Phase = "updating"
	if job.path == "" {
		path, err := geoPath(m.home, job.id)
		if err != nil {
			m.publishLocked()
			return errors.New("geo_io")
		}
		job.path, m.paths[job.id], item.FileName = path, path, filepath.Base(path)
	}
	metadata := m.metadata[job.id]
	if !m.metadataOK[job.id] {
		metadata = geoMetadata{Version: 1}
	}
	metadata.LastAttemptAt = m.now().UnixMilli()
	m.metadata[job.id] = metadata
	if err := writeGeoMetadata(m.home, job.id, metadata); err != nil {
		m.publishLocked()
		return err
	}
	m.metadataOK[job.id] = true
	m.publishLocked()
	return nil
}

func (m *geoManager) update(job *geoJob) (outcome string, resultErr error) {
	ctx, cancel := context.WithTimeout(job.ctx, geoDownloadTimeout)
	defer cancel()
	defer func() {
		if resultErr == nil {
			return
		}
		if ctx.Err() != nil {
			resultErr = geoContextError(ctx)
		}
		outcome = "failed"
		if resultErr.Error() == "geo_canceled" {
			outcome = "canceled"
		}
	}()
	if err := m.beginAttempt(job); err != nil {
		return "", err
	}
	if !validGeoURL(job.source) {
		return "", errors.New("geo_invalid_url")
	}
	requestCtx, finishRuleRequest := ruleRequestContext(ctx)
	defer finishRuleRequest()
	request, err := http.NewRequestWithContext(requestCtx, http.MethodGet, job.source, nil)
	if err != nil {
		return "", errors.New("geo_invalid_url")
	}
	transport, err := newRuleTransport()
	if err != nil {
		return "", errors.New("geo_download_failed")
	}
	defer transport.CloseIdleConnections()
	invalidRedirect := false
	client := &http.Client{Transport: transport, CheckRedirect: func(request *http.Request, via []*http.Request) error {
		if len(via) > 10 {
			return errors.New("geo_download_failed")
		}
		if !validGeoURL(request.URL.String()) {
			invalidRedirect = true
			return errors.New("geo_invalid_url")
		}
		// 资源请求不继承 controller 的鉴权，也不向重定向站点转发凭据。
		request.Header.Del("Authorization")
		request.Header.Del("Proxy-Authorization")
		return nil
	}}
	response, err := client.Do(request)
	if err != nil {
		if invalidRedirect {
			return "", errors.New("geo_invalid_url")
		}
		return "", errors.New("geo_download_failed")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("geo_http_%03d", response.StatusCode)
	}
	if response.ContentLength > geoDownloadLimit {
		return "", errors.New("geo_invalid_data")
	}
	file, err := os.CreateTemp(filepath.Dir(job.path), "arkclash-geo-"+string(job.id)+"-*.tmp")
	if err != nil {
		return "", errors.New("geo_io")
	}
	path := file.Name()
	defer os.Remove(path)
	hash := sha256.New()
	total := max(0, response.ContentLength)
	m.reportDownload(job, 0, total)
	var received int64
	nextReport := time.Now().Add(time.Second)
	reader := geoContextReader{ctx: ctx, reader: response.Body, onRead: func(n int) {
		received += int64(n)
		if now := time.Now(); !now.Before(nextReport) {
			m.reportDownload(job, received, total)
			nextReport = now.Add(time.Second)
		}
	}}
	n, copyErr := io.Copy(io.MultiWriter(file, hash), io.LimitReader(reader, geoDownloadLimit+1))
	m.reportDownload(job, received, total)
	if copyErr == nil && (n == 0 || n > geoDownloadLimit) {
		copyErr = errors.New("geo_invalid_data")
	}
	// 数据刷盘和候选校验都在锁外完成，提交阶段只换文件及 reader。
	if copyErr == nil {
		if err := file.Sync(); err != nil {
			copyErr = errors.New("geo_io")
		}
	}
	if err := file.Close(); copyErr == nil && err != nil {
		copyErr = errors.New("geo_io")
	}
	if copyErr != nil {
		if copyErr.Error() == "geo_invalid_data" || copyErr.Error() == "geo_io" {
			return "", copyErr
		}
		var pathError *os.PathError
		if errors.As(copyErr, &pathError) {
			return "", errors.New("geo_io")
		}
		return "", errors.New("geo_download_failed")
	}
	candidate, err := validateGeoCandidate(ctx, job.id, path)
	if err != nil {
		return "", err
	}
	if candidate != nil {
		defer func() {
			if candidate != nil {
				_ = candidate.Close()
			}
		}()
	}
	unchanged, err := geoSameContent(ctx, job.path, hash.Sum(nil))
	if err != nil {
		return "", err
	}
	if ctx.Err() != nil {
		return "", geoContextError(ctx)
	}
	info, err := os.Stat(path)
	if err != nil {
		return "", errors.New("geo_io")
	}

	mu.Lock()
	defer mu.Unlock()
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.jobValidLocked(job) || ctx.Err() != nil {
		return "", geoContextError(ctx)
	}
	metadata := m.metadata[job.id]
	metadata.Managed = true
	if err := writeGeoMetadata(m.home, job.id, metadata); err != nil {
		return "", err
	}
	m.metadata[job.id] = metadata
	if ctx.Err() != nil {
		return "", geoContextError(ctx)
	}
	if unchanged {
		return "unchanged", nil
	}
	if err := os.Rename(path, job.path); err != nil {
		return "", errors.New("geo_io")
	}
	switch job.id {
	case geoMMDB:
		mmdb.InstallIPReader(candidate)
		candidate = nil
	case geoASN:
		mmdb.InstallASNReader(candidate)
		candidate = nil
	case geoIP:
		geodata.ClearGeoIPCache()
	case geoSite:
		geodata.ClearGeoSiteCache()
	}
	item := &m.items[geoIndex(job.id)]
	item.Exists, item.Size, item.ModifiedAt = true, info.Size(), info.ModTime().UnixMilli()
	publishRuntime()
	return "updated", nil
}

func geoSameContent(ctx context.Context, path string, candidateHash []byte) (bool, error) {
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, errors.New("geo_io")
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return false, errors.New("geo_io")
	}
	if !info.Mode().IsRegular() {
		return false, errors.New("geo_io")
	}
	hash := sha256.New()
	if _, err := io.Copy(hash, geoContextReader{ctx: ctx, reader: file}); err != nil {
		if ctx.Err() != nil {
			return false, geoContextError(ctx)
		}
		return false, errors.New("geo_io")
	}
	return bytes.Equal(hash.Sum(nil), candidateHash), nil
}

func validateGeoCandidate(ctx context.Context, id geoResourceID, path string) (*maxminddb.Reader, error) {
	if ctx.Err() != nil {
		return nil, geoContextError(ctx)
	}
	if id == geoMMDB || id == geoASN {
		reader, err := maxminddb.Open(path)
		if err != nil {
			return nil, errors.New("geo_invalid_data")
		}
		validType := false
		if id == geoASN {
			switch reader.Metadata.DatabaseType {
			case "GeoLite2-ASN", "DBIP-ASN-Lite (compat=GeoLite2-ASN)", "ipinfo generic_asn_free.mmdb":
				validType = true
			}
		} else {
			// IPReader 除两种专用格式外使用通用 MaxMind 分支，不额外收窄数据库类型。
			validType = reader.Metadata.DatabaseType != ""
		}
		if !validType || reader.Verify() != nil {
			_ = reader.Close()
			return nil, errors.New("geo_invalid_data")
		}
		if ctx.Err() != nil {
			_ = reader.Close()
			return nil, geoContextError(ctx)
		}
		return reader, nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, errors.New("geo_io")
	}
	if id == geoIP {
		var list router.GeoIPList
		if proto.Unmarshal(data, &list) != nil || len(list.Entry) == 0 {
			return nil, errors.New("geo_invalid_data")
		}
		for _, entry := range list.Entry {
			if ctx.Err() != nil {
				return nil, geoContextError(ctx)
			}
			if entry == nil || strings.TrimSpace(entry.CountryCode) == "" || len(entry.Cidr) == 0 {
				return nil, errors.New("geo_invalid_data")
			}
			for _, cidr := range entry.Cidr {
				if cidr == nil || (len(cidr.Ip) != 4 && len(cidr.Ip) != 16) || cidr.Prefix > uint32(len(cidr.Ip)*8) {
					return nil, errors.New("geo_invalid_data")
				}
			}
		}
	} else if id == geoSite {
		var list router.GeoSiteList
		if proto.Unmarshal(data, &list) != nil || len(list.Entry) == 0 {
			return nil, errors.New("geo_invalid_data")
		}
		for _, entry := range list.Entry {
			if ctx.Err() != nil {
				return nil, geoContextError(ctx)
			}
			if entry == nil || strings.TrimSpace(entry.CountryCode) == "" || len(entry.Domain) == 0 {
				return nil, errors.New("geo_invalid_data")
			}
			for _, domain := range entry.Domain {
				if domain == nil || strings.TrimSpace(domain.Value) == "" {
					return nil, errors.New("geo_invalid_data")
				}
				switch domain.Type {
				case router.Domain_Plain, router.Domain_Domain, router.Domain_Full:
				case router.Domain_Regex:
					if _, err := regexp.Compile(domain.Value); err != nil {
						return nil, errors.New("geo_invalid_data")
					}
				default:
					return nil, errors.New("geo_invalid_data")
				}
			}
		}
	} else {
		return nil, errors.New("geo_invalid_settings")
	}
	if ctx.Err() != nil {
		return nil, geoContextError(ctx)
	}
	return nil, nil
}
