package main

import (
	"strings"
	"time"

	"github.com/metacubex/mihomo/dns"
	D "github.com/miekg/dns"
)

type DiagnosticDnsRecord struct {
	ID        string   `json:"id"`
	Domain    string   `json:"domain"`
	Type      string   `json:"type"`
	Initiator string   `json:"initiator"`
	Upstream  string   `json:"upstream"`
	Rcode     string   `json:"rcode"`
	Error     string   `json:"error"`
	Cached    bool     `json:"cached"`
	Answers   []string `json:"answers"`
	Delay     int64    `json:"delay"`
	Time      string   `json:"time"`
}

type diagnosticDNSFrame struct {
	diagnosticHeader
	Records []DiagnosticDnsRecord `json:"records"`
	Added   []DiagnosticDnsRecord `json:"added"`
}

func diagnosticDNSRecord(record dns.QueryRecord, id string, now time.Time) DiagnosticDnsRecord {
	delay := now.Sub(record.Start).Milliseconds()
	if delay < 0 {
		delay = 0
	}
	initiator := record.Initiator
	switch initiator {
	case "app", "rule", "direct", "proxy", "other":
	default:
		initiator = "other"
	}
	query := DiagnosticDnsRecord{ID: id, Domain: strings.TrimSuffix(record.Question.Name, "."), Type: D.Type(record.Question.Qtype).String(),
		Initiator: initiator, Upstream: record.Upstream, Cached: record.Cached, Answers: []string{}, Delay: delay, Time: record.Start.Format(time.RFC3339Nano)}
	if record.Err != nil {
		query.Error = record.Err.Error()
	}
	if record.Msg == nil {
		return query
	}
	query.Rcode = D.RcodeToString[record.Msg.Rcode]
	for _, rr := range record.Msg.Answer {
		var answer string
		switch value := rr.(type) {
		case *D.A:
			answer = value.A.String()
		case *D.AAAA:
			answer = value.AAAA.String()
		case *D.CNAME:
			answer = strings.TrimSuffix(value.Target, ".")
		default:
			answer = strings.TrimSpace(strings.TrimPrefix(rr.String(), rr.Header().String()))
		}
		query.Answers = append(query.Answers, answer)
	}
	return query
}

func (c *diagnosticCollector) observeDNS(record dns.QueryRecord) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return
	}
	query := diagnosticDNSRecord(record, diagnosticID(), time.Now())
	if len(c.dnsRecords) < diagnosticDNSLimit {
		c.dnsRecords = append(c.dnsRecords, query)
	} else {
		c.evicted++
		c.dnsRecords[c.dnsHead] = query
		c.dnsHead = (c.dnsHead + 1) % diagnosticDNSLimit
	}
	if len(c.sessions) != 0 {
		c.broadcastLocked(diagnosticEvent{kind: "dns", dns: query})
	}
}

func (c *diagnosticCollector) dnsSnapshotLocked(s *diagnosticSession, kind string, now time.Time) diagnosticDNSFrame {
	frame := diagnosticDNSFrame{diagnosticHeader: c.headerLocked(s, kind, now),
		Records: make([]DiagnosticDnsRecord, len(c.dnsRecords)), Added: []DiagnosticDnsRecord{}}
	for i := range c.dnsRecords {
		frame.Records[i] = c.dnsRecords[(c.dnsHead+i)%len(c.dnsRecords)]
	}
	return frame
}

func (c *diagnosticCollector) dnsDeltaLocked(s *diagnosticSession, now time.Time) diagnosticDNSFrame {
	frame := diagnosticDNSFrame{diagnosticHeader: c.headerLocked(s, "delta", now), Records: []DiagnosticDnsRecord{}, Added: []DiagnosticDnsRecord{}}
	for _, event := range s.queue {
		if event.kind == "dns" {
			frame.Added = append(frame.Added, event.dns)
		}
	}
	return frame
}
