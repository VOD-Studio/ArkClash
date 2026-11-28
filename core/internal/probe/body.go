package probe

import (
	"errors"
	"io"
	"regexp"
)

const (
	probeSmallLimit = 16 << 10
	probeHTMLLimit  = 512 << 10
	JSONLimit       = 64 << 10
	probeScanLimit  = 8 << 20
	ScanChunk       = 32 << 10
	ScanOverlap     = 256
)

func ReadBody(body io.Reader, mode string, pattern *regexp.Regexp) (string, error) {
	var limit int64
	switch mode {
	case "none":
		return "", nil
	case "small":
		limit = probeSmallLimit
	case "html":
		limit = probeHTMLLimit
	case "json":
		data, err := io.ReadAll(io.LimitReader(body, JSONLimit+1))
		if err != nil {
			return "", err
		}
		if len(data) > JSONLimit {
			return "", errors.New("probe_json_too_large")
		}
		return string(data), nil
	case "scan":
		return scanProbeBody(body, pattern)
	default:
		return "", errors.New("invalid_probe_body_mode")
	}
	data, err := io.ReadAll(io.LimitReader(body, limit))
	return string(data), err
}

func scanProbeBody(body io.Reader, pattern *regexp.Regexp) (string, error) {
	window := make([]byte, ScanChunk+ScanOverlap)
	retained, total := 0, 0
	for total < probeScanLimit {
		length := min(ScanChunk, probeScanLimit-total)
		n, err := body.Read(window[retained : retained+length])
		total += n
		available := retained + n
		if match := pattern.FindIndex(window[:available]); match != nil {
			// 保留本次已读窗口中的后续证据，避免地区字段盖过同窗的拒绝标记。
			return string(window[match[0]:available]), nil
		}
		if err != nil {
			if err == io.EOF {
				return "", nil
			}
			return "", err
		}
		// 只保留边界附近的片段；页面正文不会累积到 UI 的 JSON 信封中。
		retained = min(available, ScanOverlap)
		copy(window, window[available-retained:available])
	}
	return "", nil
}
