package main

import (
	"errors"
	"strings"
	"time"

	"github.com/metacubex/mihomo/log"
)

const diagnosticLogLimit = 5000

var errDiagnosticLogsDisabled = errors.New("diagnostic_logs_disabled")
var diagnosticLogs *diagnosticCollector

type diagnosticLogRecord struct {
	ID    string `json:"id"`
	Time  int64  `json:"time"`
	Level string `json:"level"`
	diagnosticLogText
}

type diagnosticLogText struct {
	Event   string `json:"event"`
	Message string `json:"message"`
	Reason  string `json:"reason,omitempty"`
}

type diagnosticLogsFrame struct {
	diagnosticHeader
	Logs []diagnosticLogRecord `json:"logs"`
}

// 变量参数可能有订阅、节点和凭据。动态拼接后作为 format 传入的正文也不能直接输出。
func describeDiagnosticLog(event log.Event) diagnosticLogText {
	switch event.Template {
	case "[ArkClash] core started":
		return diagnosticLogText{Event: "core_started", Message: event.Template}
	case "[ArkClash] external controller port unavailable":
		return diagnosticLogText{Event: "controller_unavailable", Message: event.Template}
	case "[ArkClash] core stopped with pending VPN resources: %s":
		return diagnosticLogText{Event: "vpn_cleanup", Message: "[ArkClash] core stopped with pending VPN resources"}
	case "[ArkClash] reloaded profile %s":
		return diagnosticLogText{Event: "profile_reloaded", Message: "[ArkClash] profile reloaded"}
	case "[%s] %s --> %s using DIRECT":
		return diagnosticLogText{Event: "route_direct", Message: "Connection established via DIRECT"}
	case "[%s] %s --> %s using GLOBAL", "[%s] %s --> %s using %s", "[%s] %s --> %s match %s using %s",
		"[%s] %s --> %s doesn't match any rule using %s":
		return diagnosticLogText{Event: "route_selected", Message: "Connection established through selected route"}
	case "[%s] dial %s %s --> %s error: %s", "[%s] dial %s (match %s/%s) %s --> %s error: %s":
		reason := diagnosticLogCause(event.Payload)
		return diagnosticLogText{Event: "dial_failed", Message: "Connection failed: " + reason, Reason: reason}
	case "[DNS] hijack udp:%s from %s":
		return diagnosticLogText{Event: "dns_udp", Message: "[DNS] hijack udp:… from …"}
	case "[DNS] hijack tcp:%s":
		return diagnosticLogText{Event: "dns_tcp", Message: "[DNS] hijack tcp:…"}
	case "[DNS] cache hit %s --> %s, expire at %s":
		return diagnosticLogText{Event: "dns_cache", Message: "[DNS] cache hit …"}
	case "[DNS] resolve %s %s from %s":
		return diagnosticLogText{Event: "dns_query", Message: "[DNS] resolve … from …"}
	case "[DNS] %s --> %s", "[DNS] %s --> %s from %s":
		return diagnosticLogText{Event: "dns_answer", Message: "[DNS] query answered"}
	case "[DNS] resolve %s error: %s":
		return diagnosticLogText{Event: "dns_failed", Message: "[DNS] resolve failed"}
	case "[Rule] use default rules":
		return diagnosticLogText{Event: "default_rules", Message: event.Template}
	case "[Rule] use %s rules":
		return diagnosticLogText{Event: "named_rules", Message: "[Rule] use named rules"}
	case "XTLS Vision direct read start", "XTLS Vision direct write start":
		return diagnosticLogText{Event: "vision_direct", Message: event.Template}
	default:
		if text := log.ArkClashStaticLogMessage(event.Template); text != "" {
			return diagnosticLogText{Event: "template", Message: text}
		}
		return diagnosticLogText{Event: "other", Message: "Core event"}
	}
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
			event.Payload = strings.Clone(event.Payload[:1024])
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

func stopDiagnosticLogsLocked() func() {
	workers := retireDiagnosticCollectorLocked(diagnosticLogs, false)
	return func() { waitDiagnosticWorkers(workers) }
}
