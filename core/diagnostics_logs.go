package main

import (
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/log"
)

const diagnosticLogLimit = 5000

var errDiagnosticLogsDisabled = errors.New("diagnostic_logs_disabled")

var (
	logTagPrefixPattern = regexp.MustCompile(`(?s)^\[([^\]]+)\] (.+)$`)
	logSafeTagPattern   = regexp.MustCompile(`^[A-Za-z0-9 _.-]{1,24}$`)
	logRoutePattern     = regexp.MustCompile(`^((?:\[[^\]]+\]|[^\s\[\]()]+):\d+|mihomo)(?:\((.*)\))? --> (\S+) (?:(?:match (.+?)|(doesn't match any rule)) )?using (.+)$`)
	logDialPattern      = regexp.MustCompile(`(?s)^dial (.+?) (?:\(match (.+?)\) )?((?:\[[^\]]+\]|[^\s\[\]()]+):\d+|mihomo)(?:\((.*)\))? --> (\S+) error: (.+)$`)
	logICMPPattern      = regexp.MustCompile(`^(\S+) (\S+) --> (\S+) using (.+)$`)
	logDNSUDPPattern    = regexp.MustCompile(`^\[DNS\] hijack udp:(\S+) from (\S+)$`)
	logDNSTCPPattern    = regexp.MustCompile(`^\[DNS\] hijack tcp:(\S+)$`)
	logDNSQueryPattern  = regexp.MustCompile(`^\[DNS\] resolve (\S+) (\S+) from (.+)$`)
	logSniffOKPattern   = regexp.MustCompile(`^\[Sniffer\] Sniff (\S+) \[([^\]]+)\]-->\[([^\]]+)\] success, replace domain \[([^\]]*)\]-->\[([^\]]+)\]$`)
	logWGPattern        = regexp.MustCompile(`(?s)^\[WG\]\([^)]*\)\s*(.+)$`)

	logSecretKVPattern    = regexp.MustCompile(`(?i)\b(authorization|token|password|passwd|pwd|secret|private_key|preshared_key|api[_-]?key|access[_-]?key|auth)\s*[:=]\s*\S+`)
	logBearerPattern      = regexp.MustCompile(`(?i)\bbearer\s+\S+`)
	logURLPattern         = regexp.MustCompile(`([A-Za-z][A-Za-z0-9+.-]*)://[^\s"'<>)\]]+`)
	logUserInfoPattern    = regexp.MustCompile(`[^\s/@:]+:[^\s/@]+@[^\s"'<>)\]]+`)
	logLookupHostPattern  = regexp.MustCompile(`(?i)\blookup\s+[^\s:]+`)
	logIPv6BracketPattern = regexp.MustCompile(`\[[0-9a-fA-F:]+(?:%[^\]]+)?\](?::\d+)?`)
	logIPv4Pattern        = regexp.MustCompile(`\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b`)
	logIPv6BarePattern    = regexp.MustCompile(`(?i)(?:(?:[0-9a-f]{1,4}:){3,}[0-9a-f:]*|[0-9a-f]{1,4}::[0-9a-f:]*|::[0-9a-f:]+)(?:%[a-z0-9_.-]+)?`)
)

type diagnosticLogRecord struct {
	ID    string `json:"id"`
	Time  int64  `json:"time"`
	Level string `json:"level"`
	diagnosticLogText
}

type diagnosticLogText struct {
	Event   string `json:"event"`
	Tag     string `json:"tag,omitempty"`
	Message string `json:"message"`
	Reason  string `json:"reason,omitempty"`
	Target  string `json:"target,omitempty"`
	Source  string `json:"source,omitempty"`
	Rule    string `json:"rule,omitempty"`
	Proxy   string `json:"proxy,omitempty"`
	Detail  string `json:"detail,omitempty"`
}

type diagnosticLogsFrame struct {
	diagnosticHeader
	Logs []diagnosticLogRecord `json:"logs"`
}

func truncateLogUTF8(s string, maxBytes int) string {
	if len(s) <= maxBytes {
		return s
	}
	if maxBytes <= 0 {
		return ""
	}
	end := maxBytes
	for end > 0 && !utf8.RuneStart(s[end]) {
		end--
	}
	return strings.Clone(s[:end])
}

func cleanLogField(raw string, maxBytes int) string {
	cleaned := strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, raw)
	cleaned = strings.Join(strings.Fields(cleaned), " ")
	if len(cleaned) > maxBytes {
		return truncateLogUTF8(cleaned, maxBytes) + "…"
	}
	return cleaned
}

// 脱敏自由文本中的链接、凭据、私钥、解析域名和裸 IP，避免代理服务器地址或订阅凭据进入日志与导出文件。
func sanitizeLogText(raw string) string {
	lower := strings.ToLower(raw)
	if strings.Contains(lower, "private_key=") || strings.Contains(lower, "preshared_key=") ||
		strings.Contains(lower, "wireguard ipc conf") {
		return "WireGuard IPC config updated"
	}
	text := strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, raw)
	text = logURLPattern.ReplaceAllString(text, "${1}://…")
	text = logBearerPattern.ReplaceAllString(text, "Bearer …")
	text = logSecretKVPattern.ReplaceAllString(text, "${1}=…")
	text = logUserInfoPattern.ReplaceAllString(text, "…")
	text = logLookupHostPattern.ReplaceAllString(text, "lookup …")
	text = logIPv6BracketPattern.ReplaceAllString(text, "…")
	text = logIPv4Pattern.ReplaceAllString(text, "…")
	text = logIPv6BarePattern.ReplaceAllString(text, "…")
	text = strings.Join(strings.Fields(text), " ")
	if text == "" || text == "…" {
		return ""
	}
	if len(text) > 256 {
		return truncateLogUTF8(text, 256) + "…"
	}
	return text
}

// 保留公共 DNS 上游协议与主机名，剥离凭据、查询参数和可能含私有 ID 的路径。
func sanitizeDNSUpstream(raw string) string {
	trimmed := cleanLogField(raw, 192)
	if trimmed == "" {
		return ""
	}
	if strings.Contains(trimmed, "://") {
		parsed, err := url.Parse(trimmed)
		if err != nil || parsed.Scheme == "" {
			return "…"
		}
		if parsed.Scheme == "system" {
			return "system://"
		}
		if parsed.Host == "" {
			return parsed.Scheme + "://…"
		}
		path := parsed.Path
		if path != "" && path != "/" && path != "/dns-query" {
			path = "/…"
		}
		return parsed.Scheme + "://" + parsed.Host + path
	}
	return logUserInfoPattern.ReplaceAllString(trimmed, "…")
}

func normalizeDialRule(raw string) string {
	raw = cleanLogField(raw, 160)
	if raw == "" {
		return ""
	}
	if ruleType, payload, ok := strings.Cut(raw, "/"); ok {
		if payload == "" {
			return ruleType
		}
		return ruleType + "(" + payload + ")"
	}
	return raw
}

func parseRouteDiagnosticLog(event log.Event, direct bool) diagnosticLogText {
	fallbackEvent := "route_selected"
	fallbackMsg := "Connection established through selected route"
	if direct {
		fallbackEvent = "route_direct"
		fallbackMsg = "Connection established via DIRECT"
	}
	tagged := logTagPrefixPattern.FindStringSubmatch(event.Payload)
	if len(tagged) != 3 {
		return diagnosticLogText{Event: fallbackEvent, Message: fallbackMsg}
	}
	tag := cleanLogField(tagged[1], 24)
	match := logRoutePattern.FindStringSubmatch(tagged[2])
	if len(match) != 7 {
		return diagnosticLogText{Event: fallbackEvent, Tag: tag, Message: fallbackMsg}
	}
	source := cleanLogField(match[1], 96)
	target := cleanLogField(match[3], 192)
	rule := cleanLogField(match[4], 160)
	if rule == "" {
		rule = cleanLogField(match[5], 160)
	}
	proxy := cleanLogField(match[6], 160)
	var msg strings.Builder
	msg.WriteByte('[')
	msg.WriteString(tag)
	msg.WriteString("] ")
	msg.WriteString(source)
	msg.WriteString(" --> ")
	msg.WriteString(target)
	if rule != "" {
		if rule == "doesn't match any rule" {
			msg.WriteString(" doesn't match any rule")
		} else {
			msg.WriteString(" match ")
			msg.WriteString(rule)
		}
	}
	msg.WriteString(" using ")
	msg.WriteString(proxy)
	return diagnosticLogText{
		Event:   fallbackEvent,
		Tag:     tag,
		Message: msg.String(),
		Target:  target,
		Source:  source,
		Rule:    rule,
		Proxy:   proxy,
	}
}

func parseDialDiagnosticLog(event log.Event) diagnosticLogText {
	reason := diagnosticLogCause(event.Payload)
	tagged := logTagPrefixPattern.FindStringSubmatch(event.Payload)
	if len(tagged) != 3 {
		return diagnosticLogText{Event: "dial_failed", Message: "Connection failed: " + reason, Reason: reason}
	}
	tag := cleanLogField(tagged[1], 24)
	match := logDialPattern.FindStringSubmatch(tagged[2])
	if len(match) != 7 {
		return diagnosticLogText{Event: "dial_failed", Tag: tag, Message: "Connection failed: " + reason, Reason: reason}
	}
	proxy := cleanLogField(match[1], 160)
	rule := normalizeDialRule(match[2])
	source := cleanLogField(match[3], 96)
	target := cleanLogField(match[5], 192)
	detail := sanitizeLogText(match[6])
	if detail == "" {
		detail = reason
	}
	var msg strings.Builder
	msg.WriteByte('[')
	msg.WriteString(tag)
	msg.WriteString("] dial ")
	msg.WriteString(proxy)
	if rule != "" {
		msg.WriteString(" (match ")
		msg.WriteString(rule)
		msg.WriteByte(')')
	}
	msg.WriteByte(' ')
	msg.WriteString(source)
	msg.WriteString(" --> ")
	msg.WriteString(target)
	msg.WriteString(" error: ")
	msg.WriteString(detail)
	return diagnosticLogText{
		Event:   "dial_failed",
		Tag:     tag,
		Message: msg.String(),
		Reason:  reason,
		Target:  target,
		Source:  source,
		Rule:    rule,
		Proxy:   proxy,
		Detail:  detail,
	}
}

func parseDNSDiagnosticLog(event log.Event) (diagnosticLogText, bool) {
	switch event.Template {
	case "[DNS] hijack udp:%s from %s":
		if m := logDNSUDPPattern.FindStringSubmatch(event.Payload); len(m) == 3 {
			target := "udp:" + cleanLogField(m[1], 128)
			source := cleanLogField(m[2], 96)
			return diagnosticLogText{
				Event:   "dns_udp",
				Tag:     "DNS",
				Target:  target,
				Source:  source,
				Message: "[DNS] hijack " + target + " from " + source,
			}, true
		}
		return diagnosticLogText{Event: "dns_udp", Tag: "DNS", Message: "[DNS] hijack udp:… from …"}, true
	case "[DNS] hijack tcp:%s":
		if m := logDNSTCPPattern.FindStringSubmatch(event.Payload); len(m) == 2 {
			target := "tcp:" + cleanLogField(m[1], 128)
			return diagnosticLogText{
				Event:   "dns_tcp",
				Tag:     "DNS",
				Target:  target,
				Message: "[DNS] hijack " + target,
			}, true
		}
		return diagnosticLogText{Event: "dns_tcp", Tag: "DNS", Message: "[DNS] hijack tcp:…"}, true
	case "[DNS] cache hit %s --> %s, expire at %s":
		if body, ok := strings.CutPrefix(event.Payload, "[DNS] cache hit "); ok {
			if domain, rest, ok := strings.Cut(body, " --> "); ok {
				answers, _, _ := strings.Cut(rest, ", expire at ")
				domain = cleanLogField(domain, 192)
				answers = cleanLogField(answers, 192)
				if domain != "" {
					return diagnosticLogText{
						Event:   "dns_cache",
						Tag:     "DNS",
						Target:  domain,
						Detail:  answers,
						Message: "[DNS] cache hit " + domain + " --> " + answers,
					}, true
				}
			}
		}
		return diagnosticLogText{Event: "dns_cache", Tag: "DNS", Message: "[DNS] cache hit …"}, true
	case "[DNS] resolve %s %s from %s":
		if m := logDNSQueryPattern.FindStringSubmatch(event.Payload); len(m) == 4 {
			domain := cleanLogField(m[1], 192)
			qtype := cleanLogField(m[2], 24)
			upstream := sanitizeDNSUpstream(m[3])
			detail := qtype
			if upstream != "" {
				detail = qtype + " · " + upstream
			}
			return diagnosticLogText{
				Event:   "dns_query",
				Tag:     "DNS",
				Target:  domain,
				Detail:  detail,
				Message: "[DNS] resolve " + domain + " " + qtype + " from " + upstream,
			}, true
		}
		return diagnosticLogText{Event: "dns_query", Tag: "DNS", Message: "[DNS] resolve … from …"}, true
	case "[DNS] %s --> %s", "[DNS] %s --> %s from %s":
		if body, ok := strings.CutPrefix(event.Payload, "[DNS] "); ok {
			if domain, rest, ok := strings.Cut(body, " --> "); ok {
				domain = cleanLogField(domain, 192)
				answers, upstream, hasUpstream := strings.Cut(rest, " from ")
				answers = cleanLogField(answers, 192)
				detail := answers
				msg := "[DNS] " + domain + " --> " + answers
				if hasUpstream {
					safeUpstream := sanitizeDNSUpstream(upstream)
					if safeUpstream != "" {
						detail = answers + " · " + safeUpstream
						msg += " from " + safeUpstream
					}
				}
				if domain != "" {
					return diagnosticLogText{
						Event:   "dns_answer",
						Tag:     "DNS",
						Target:  domain,
						Detail:  detail,
						Message: msg,
					}, true
				}
			}
		}
		return diagnosticLogText{Event: "dns_answer", Tag: "DNS", Message: "[DNS] query answered"}, true
	case "[DNS] resolve %s error: %s":
		if body, ok := strings.CutPrefix(event.Payload, "[DNS] resolve "); ok {
			if domain, errText, ok := strings.Cut(body, " error: "); ok {
				domain = cleanLogField(domain, 192)
				safeErr := sanitizeLogText(errText)
				msg := "[DNS] resolve " + domain + " failed"
				if safeErr != "" {
					msg = "[DNS] resolve " + domain + " error: " + safeErr
				}
				if domain != "" {
					return diagnosticLogText{
						Event:   "dns_failed",
						Tag:     "DNS",
						Target:  domain,
						Detail:  safeErr,
						Message: msg,
					}, true
				}
			}
		}
		return diagnosticLogText{Event: "dns_failed", Tag: "DNS", Message: "[DNS] resolve failed"}, true
	default:
		return diagnosticLogText{}, false
	}
}

func parseSnifferDiagnosticLog(event log.Event) (diagnosticLogText, bool) {
	if event.Template != "[Sniffer] Sniff %s [%s]-->[%s] success, replace domain [%s]-->[%s]" {
		return diagnosticLogText{}, false
	}
	if m := logSniffOKPattern.FindStringSubmatch(event.Payload); len(m) == 6 {
		proto := cleanLogField(m[1], 32)
		source := cleanLogField(m[2], 96)
		oldDomain := cleanLogField(m[4], 192)
		newDomain := cleanLogField(m[5], 192)
		detail := proto
		if oldDomain != "" && oldDomain != newDomain {
			detail = proto + " · " + oldDomain + " → " + newDomain
		}
		return diagnosticLogText{
			Event:   "sniffer",
			Tag:     "Sniffer",
			Target:  newDomain,
			Source:  source,
			Detail:  detail,
			Message: "[Sniffer] " + proto + " " + oldDomain + " --> " + newDomain,
		}, true
	}
	return diagnosticLogText{Event: "sniffer", Tag: "Sniffer", Message: "[Sniffer] Sniff success"}, true
}

func parseICMPDiagnosticLog(event log.Event) (diagnosticLogText, bool) {
	switch event.Template {
	case "[ICMP] %s %s --> %s using fake ping echo", "[ICMP] %s %s --> %s using DIRECT":
		if body, ok := strings.CutPrefix(event.Payload, "[ICMP] "); ok {
			if m := logICMPPattern.FindStringSubmatch(body); len(m) == 5 {
				source := cleanLogField(m[2], 96)
				target := cleanLogField(m[3], 192)
				proxy := cleanLogField(m[4], 64)
				return diagnosticLogText{
					Event:   "route_direct",
					Tag:     "ICMP",
					Source:  source,
					Target:  target,
					Proxy:   proxy,
					Message: "[ICMP] " + source + " --> " + target + " using " + proxy,
				}, true
			}
		}
		return diagnosticLogText{Event: "route_direct", Tag: "ICMP", Message: "Connection established via DIRECT"}, true
	default:
		return diagnosticLogText{}, false
	}
}

func describeStaticTemplate(text string) diagnosticLogText {
	if tagged := logTagPrefixPattern.FindStringSubmatch(text); len(tagged) == 3 && logSafeTagPattern.MatchString(tagged[1]) {
		return diagnosticLogText{Event: "template", Tag: tagged[1], Message: text}
	}
	return diagnosticLogText{Event: "template", Message: text}
}

func describeComponentLog(payload string) diagnosticLogText {
	if payload == "" {
		return diagnosticLogText{Event: "other", Message: "Core event"}
	}
	if wg := logWGPattern.FindStringSubmatch(payload); len(wg) == 2 {
		safe := sanitizeLogText(wg[1])
		if safe == "" {
			return diagnosticLogText{Event: "other", Tag: "WG", Message: "Core event"}
		}
		return diagnosticLogText{Event: "component", Tag: "WG", Message: safe}
	}
	if strings.HasPrefix(payload, "Hopped to ") {
		return diagnosticLogText{Event: "port_hop", Tag: "QUIC", Message: "Hopped to …"}
	}
	tag := ""
	body := payload
	if tagged := logTagPrefixPattern.FindStringSubmatch(payload); len(tagged) == 3 && logSafeTagPattern.MatchString(tagged[1]) {
		tag = tagged[1]
		body = tagged[2]
	}
	safe := sanitizeLogText(body)
	if safe == "" {
		return diagnosticLogText{Event: "other", Tag: tag, Message: "Core event"}
	}
	return diagnosticLogText{Event: "component", Tag: tag, Message: safe}
}

// 连接、拨号和 DNS 模板解析为结构化字段；自由错误正文与组件动态日志统一脱敏，不泄露凭据、链接或代理服务器地址。
func describeDiagnosticLog(event log.Event) diagnosticLogText {
	switch event.Template {
	case "[ArkClash] core started":
		return diagnosticLogText{Event: "core_started", Tag: "ArkClash", Message: event.Template}
	case "[ArkClash] external controller port unavailable":
		return diagnosticLogText{Event: "controller_unavailable", Tag: "ArkClash", Message: event.Template}
	case "[ArkClash] core stopped with pending VPN resources: %s":
		detail := ""
		if _, rest, ok := strings.Cut(event.Payload, ": "); ok {
			detail = sanitizeLogText(rest)
		}
		return diagnosticLogText{Event: "vpn_cleanup", Tag: "ArkClash", Message: "[ArkClash] core stopped with pending VPN resources", Detail: detail}
	case "[ArkClash] reloaded profile %s":
		return diagnosticLogText{Event: "profile_reloaded", Tag: "ArkClash", Message: "[ArkClash] profile reloaded"}
	case "[%s] %s --> %s using DIRECT":
		return parseRouteDiagnosticLog(event, true)
	case "[%s] %s --> %s using GLOBAL", "[%s] %s --> %s using %s", "[%s] %s --> %s match %s using %s",
		"[%s] %s --> %s doesn't match any rule using %s":
		return parseRouteDiagnosticLog(event, false)
	case "[%s] dial %s %s --> %s error: %s", "[%s] dial %s (match %s/%s) %s --> %s error: %s":
		return parseDialDiagnosticLog(event)
	case "[Rule] use default rules":
		return diagnosticLogText{Event: "default_rules", Tag: "Rule", Message: event.Template}
	case "[Rule] use %s rules":
		return diagnosticLogText{Event: "named_rules", Tag: "Rule", Message: "[Rule] use named rules"}
	case "XTLS Vision direct read start", "XTLS Vision direct write start":
		return diagnosticLogText{Event: "vision_direct", Tag: "XTLS", Message: event.Template}
	}
	if dnsLog, ok := parseDNSDiagnosticLog(event); ok {
		return dnsLog
	}
	if sniffLog, ok := parseSnifferDiagnosticLog(event); ok {
		return sniffLog
	}
	if icmpLog, ok := parseICMPDiagnosticLog(event); ok {
		return icmpLog
	}
	if text := log.ArkClashStaticLogMessage(event.Template); text != "" {
		return describeStaticTemplate(text)
	}
	return describeComponentLog(event.Payload)
}

func diagnosticLogCause(payload string) string {
	i := strings.LastIndex(payload, " error: ")
	if i < 0 {
		return "dial error"
	}
	payload = strings.ToLower(payload[i+len(" error: "):])
	for _, cause := range []string{"certificate", "connection refused", "timeout", "no such host", "network is unreachable", "authentication"} {
		if strings.Contains(payload, cause) {
			return cause
		}
	}
	if strings.Contains(payload, "deadline exceeded") || strings.Contains(payload, "timed out") {
		return "timeout"
	}
	return "dial error"
}

func (c *diagnosticCollector) collectLogs() {
	input := make(chan log.Event, diagnosticQueueLimit)
	log.SetArkClashLogObserver(func(event log.Event) {
		if len(event.Payload) > 1024 {
			event.Payload = truncateLogUTF8(event.Payload, 1024)
		}
		if len(event.Template) > 512 {
			event.Template = ""
		}
		select {
		case input <- event:
		default:
			c.logDropped.Add(1)
		}
	})
	c.logDone = make(chan struct{})
	go func() {
		defer close(c.logDone)
		for {
			select {
			case <-c.stop:
				return
			case event := <-input:
				c.appendLog(diagnosticLogRecord{ID: diagnosticID(), Time: time.Now().UnixMilli(),
					Level: event.Type(), diagnosticLogText: describeDiagnosticLog(event)})
			}
		}
	}()
}

func (c *diagnosticCollector) appendLog(record diagnosticLogRecord) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return
	}
	if len(c.logs) == diagnosticLogLimit {
		c.logs[c.logHead] = record
		c.logHead = (c.logHead + 1) % diagnosticLogLimit
		c.evicted++
	} else {
		c.logs = append(c.logs, record)
	}
	c.broadcastLocked(diagnosticEvent{kind: "log", log: record})
}

func (c *diagnosticCollector) logsFrameLocked(s *diagnosticSession, kind string, now time.Time) diagnosticLogsFrame {
	frame := diagnosticLogsFrame{diagnosticHeader: c.headerLocked(s, kind, now)}
	if kind == "delta" {
		frame.Logs = make([]diagnosticLogRecord, 0, len(s.queue))
		for _, event := range s.queue {
			frame.Logs = append(frame.Logs, event.log)
		}
	} else {
		frame.Logs = make([]diagnosticLogRecord, len(c.logs))
		for i := range frame.Logs {
			frame.Logs[i] = c.logs[(c.logHead+i)%len(c.logs)]
		}
	}
	return frame
}

func (h *diagnosticsHub) clearLogsLocked() {
	c := h.logs
	if c == nil {
		return
	}
	now := time.Now()
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return
	}
	c.logs = nil
	c.logHead = 0
	c.evicted = 0
	c.logDropped.Store(0)
	for s := range c.sessions {
		if s.closed {
			continue
		}
		clear(s.queue)
		s.queue = s.queue[:0]
		s.dropped = 0
		if s.initial != nil {
			s.initial = c.logsFrameLocked(s, "snapshot", now)
		} else {
			s.needsReset = true
			s.lastFrame = time.Time{}
		}
		s.signalLocked()
	}
	c.kickLocked()
}

type diagnosticLogClearRequest struct {
	ExpectedBootID string `json:"expectedBootId"`
}

func readDiagnosticLogClear(r *http.Request) (diagnosticLogClearRequest, error) {
	var request diagnosticLogClearRequest
	body, err := io.ReadAll(io.LimitReader(r.Body, 4097))
	var fields map[string]json.RawMessage
	if err != nil || len(body) > 4096 || json.Unmarshal(body, &fields) != nil || json.Unmarshal(body, &request) != nil ||
		request.ExpectedBootID == "" {
		return request, errors.New("diagnostics_invalid_request")
	}
	for key := range fields {
		if key != "expectedBootId" {
			return request, errors.New("diagnostics_invalid_request")
		}
	}
	return request, nil
}

func postDiagnosticLogsClear(w http.ResponseWriter, r *http.Request) {
	request, err := readDiagnosticLogClear(r)
	if err != nil {
		writeError(w, r, http.StatusBadRequest, err)
		return
	}
	h := eng.diag
	h.mu.Lock()
	status, err := h.bootErrorLocked(request.ExpectedBootID)
	if err == nil {
		h.clearLogsLocked()
	}
	h.mu.Unlock()
	if err != nil {
		writeError(w, r, status, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
