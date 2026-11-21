package main

import (
	"errors"
	"regexp"
	"strings"
	"time"

	"github.com/metacubex/mihomo/log"
)

const diagnosticLogLimit = 5000

var errDiagnosticLogsDisabled = errors.New("diagnostic_logs_disabled")
var diagnosticLogs *diagnosticCollector
var logFormatVerb = regexp.MustCompile(`%(?:\[[0-9]+\])?[-+#0 .0-9]*[a-zA-Z%]`)
var logTemplateURL = regexp.MustCompile(`[A-Za-z][A-Za-z0-9+.-]*://[^\s]+`)

type diagnosticLogRecord struct {
	ID      string `json:"id"`
	Time    int64  `json:"time"`
	Level   string `json:"level"`
	Message string `json:"message"`
}

type diagnosticLogsFrame struct {
	diagnosticHeader
	Logs []diagnosticLogRecord `json:"logs"`
}

// 变量参数可能有订阅、节点和凭据。动态拼接后作为 format 传入的正文也不能直接输出。
func diagnosticLogMessage(event log.Event) string {
	switch event.Template {
	case "[ArkClash] core started", "[ArkClash] external controller port unavailable":
		return event.Template
	case "[ArkClash] core stopped with pending VPN resources: %s":
		return "[ArkClash] core stopped with pending VPN resources"
	case "[ArkClash] reloaded profile %s":
		return "[ArkClash] profile reloaded"
	case "[%s] %s --> %s using DIRECT":
		return "Connection established via DIRECT"
	case "[%s] %s --> %s using GLOBAL", "[%s] %s --> %s using %s", "[%s] %s --> %s match %s using %s",
		"[%s] %s --> %s doesn't match any rule using %s":
		return "Connection established through selected route"
	case "[%s] dial %s %s --> %s error: %s", "[%s] dial %s (match %s/%s) %s --> %s error: %s":
		return "Connection failed: " + diagnosticLogCause(event.Payload)
	}
	if !logFormatVerb.MatchString(event.Template) {
		return "Core event"
	}
	body := logFormatVerb.ReplaceAllString(event.Template, "…")
	body = logTemplateURL.ReplaceAllString(body, "…")
	body = strings.Join(strings.Fields(body), " ")
	if len(body) > 256 {
		return "Core event"
	}
	return body
}

func diagnosticLogCause(payload string) string {
	payload = strings.ToLower(payload)
	for _, cause := range []string{"certificate", "connection refused", "timeout", "no such host", "network is unreachable", "authentication"} {
		if strings.Contains(payload, cause) {
			return cause
		}
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
					Level: event.Type(), Message: diagnosticLogMessage(event)})
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
