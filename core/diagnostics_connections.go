package main

import (
	"net/netip"
	"sort"
	"strconv"
	"time"

	"github.com/metacubex/mihomo/tunnel/statistic"
)

type DiagnosticMetadata struct {
	Network           string   `json:"network"`
	Type              string   `json:"type"`
	SourceIP          string   `json:"sourceIP"`
	SourcePort        string   `json:"sourcePort"`
	DestinationIP     string   `json:"destinationIP"`
	DestinationPort   string   `json:"destinationPort"`
	Host              string   `json:"host"`
	DNSMode           string   `json:"dnsMode"`
	RemoteDestination string   `json:"remoteDestination"`
	SourceIPASN       string   `json:"sourceIPASN"`
	DestinationIPASN  string   `json:"destinationIPASN"`
	SpecialProxy      string   `json:"specialProxy"`
	SpecialRules      string   `json:"specialRules"`
	SniffHost         string   `json:"sniffHost"`
	SourceGeoIP       []string `json:"sourceGeoIP"`
	DestinationGeoIP  []string `json:"destinationGeoIP"`
}

type DiagnosticConnection struct {
	ID             string             `json:"id"`
	Start          string             `json:"start"`
	Metadata       DiagnosticMetadata `json:"metadata"`
	Chains         []string           `json:"chains"`
	ProviderChains []string           `json:"providerChains"`
	Rule           string             `json:"rule"`
	RulePayload    string             `json:"rulePayload"`
	Upload         int64              `json:"upload"`
	Download       int64              `json:"download"`
}

type diagnosticTraffic struct {
	ID       string `json:"id"`
	Upload   int64  `json:"upload"`
	Download int64  `json:"download"`
}

type diagnosticConnectionsFrame struct {
	diagnosticHeader
	Live    []DiagnosticConnection `json:"live"`
	Recent  []DiagnosticConnection `json:"recent"`
	Opened  []DiagnosticConnection `json:"opened"`
	Traffic []diagnosticTraffic    `json:"traffic"`
	Closed  []string               `json:"closed"`
}

type diagnosticConnectionEntry struct {
	dto      DiagnosticConnection
	info     *statistic.TrackerInfo
	observed uint64
	live     bool
	recent   bool
	closed   bool
	stable   int
}

func diagnosticStrings(values []string) []string { return append([]string{}, values...) }
func diagnosticAddress(address netip.Addr) string {
	if address.IsValid() {
		return address.String()
	}
	return ""
}
func diagnosticCounter(value int64) int64 {
	if value < 0 {
		return 0
	}
	return value
}

func newDiagnosticConnection(tracker statistic.Tracker) *diagnosticConnectionEntry {
	info := tracker.Info()
	dto := DiagnosticConnection{ID: tracker.ID(), Start: info.Start.Format(time.RFC3339Nano), Chains: diagnosticStrings(info.Chain),
		ProviderChains: diagnosticStrings(info.ProviderChain), Rule: info.Rule, RulePayload: info.RulePayload,
		Upload: diagnosticCounter(info.UploadTotal.Load()), Download: diagnosticCounter(info.DownloadTotal.Load()),
		Metadata: DiagnosticMetadata{SourceGeoIP: []string{}, DestinationGeoIP: []string{}}}
	if m := info.Metadata; m != nil {
		dto.Metadata = DiagnosticMetadata{Network: m.NetWork.String(), Type: m.Type.String(), SourceIP: diagnosticAddress(m.SrcIP),
			SourcePort: strconv.FormatUint(uint64(m.SrcPort), 10), DestinationIP: diagnosticAddress(m.DstIP), DestinationPort: strconv.FormatUint(uint64(m.DstPort), 10),
			Host: m.Host, DNSMode: m.DNSMode.String(), RemoteDestination: m.RemoteDst, SourceIPASN: m.SrcIPASN, DestinationIPASN: m.DstIPASN,
			SpecialProxy: m.SpecialProxy, SpecialRules: m.SpecialRules, SniffHost: m.SniffHost,
			SourceGeoIP: diagnosticStrings(m.SrcGeoIP), DestinationGeoIP: diagnosticStrings(m.DstGeoIP)}
	}
	return &diagnosticConnectionEntry{dto: dto, info: info}
}

func (c *diagnosticCollector) baselineConnection(tracker statistic.Tracker) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return
	}
	if _, exists := c.connections[tracker.ID()]; exists {
		return
	}
	entry := newDiagnosticConnection(tracker)
	entry.live = true
	c.connections[entry.dto.ID] = entry
}

func (c *diagnosticCollector) openConnection(tracker statistic.Tracker) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return
	}
	entry := c.connections[tracker.ID()]
	if entry != nil && (entry.observed != 0 || entry.closed) {
		return
	}
	if entry == nil {
		entry = newDiagnosticConnection(tracker)
		c.connections[entry.dto.ID] = entry
	}
	c.observed++
	entry.observed = c.observed
	entry.live = true
	entry.recent = true
	c.appendRecentLocked(entry)
	c.broadcastLocked(diagnosticEvent{kind: "opened", connection: entry.dto, id: entry.dto.ID})
	c.scheduleSampleLocked(time.Now())
}

func (c *diagnosticCollector) appendRecentLocked(entry *diagnosticConnectionEntry) {
	if len(c.recent) < diagnosticRecentLimit {
		c.recent = append(c.recent, entry)
		return
	}
	previous := c.recent[c.recentHead]
	previous.recent = false
	for s := range c.sessions {
		if previous.observed >= s.start {
			s.evicted++
		}
	}
	if !previous.live {
		previous.info = nil
		delete(c.connections, previous.dto.ID)
	}
	c.recent[c.recentHead] = entry
	c.recentHead = (c.recentHead + 1) % diagnosticRecentLimit
}

func (c *diagnosticCollector) closeConnection(tracker statistic.Tracker) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return
	}
	entry := c.connections[tracker.ID()]
	if entry == nil {
		if !c.initializing {
			return
		}
		entry = newDiagnosticConnection(tracker)
		c.connections[entry.dto.ID] = entry
	}
	if entry.closed {
		return
	}
	entry.closed = true
	entry.live = false
	c.readTrafficLocked(entry, true)
	c.broadcastLocked(diagnosticEvent{kind: "closed", id: entry.dto.ID})
	if !entry.recent && !c.initializing {
		entry.info = nil
		delete(c.connections, entry.dto.ID)
	}
	c.scheduleSampleLocked(time.Now())
}

func (c *diagnosticCollector) readTrafficLocked(entry *diagnosticConnectionEntry, force bool) bool {
	if entry.info == nil {
		return false
	}
	upload := diagnosticCounter(entry.info.UploadTotal.Load())
	download := diagnosticCounter(entry.info.DownloadTotal.Load())
	changed := upload != entry.dto.Upload || download != entry.dto.Download
	entry.dto.Upload, entry.dto.Download = upload, download
	if changed || force {
		c.broadcastLocked(diagnosticEvent{kind: "traffic", id: entry.dto.ID,
			traffic: diagnosticTraffic{ID: entry.dto.ID, Upload: upload, Download: download}})
	}
	return changed
}

func (c *diagnosticCollector) scheduleSampleLocked(now time.Time) {
	if c.feed != "connections" || !c.sampleDue.IsZero() {
		return
	}
	for _, entry := range c.connections {
		if entry.live || entry.recent && entry.info != nil {
			c.sampleDue = now.Add(time.Second)
			c.kickLocked()
			return
		}
	}
}

func (c *diagnosticCollector) sampleConnectionsLocked(now time.Time) {
	c.sampleDue = time.Time{}
	live := false
	for _, entry := range c.connections {
		if entry.info == nil {
			continue
		}
		changed := c.readTrafficLocked(entry, false)
		if entry.live {
			live = true
			continue
		}
		if !entry.recent {
			entry.info = nil
			continue
		}
		if changed {
			entry.stable = 0
		} else {
			entry.stable++
		}
		if entry.stable >= 2 {
			entry.info = nil
		}
	}
	if live {
		for s := range c.sessions {
			s.heartbeat = true
		}
	}
	c.scheduleSampleLocked(now)
}

func (c *diagnosticCollector) releaseUnreferencedLocked() {
	for id, entry := range c.connections {
		if !entry.live && !entry.recent {
			entry.info = nil
			delete(c.connections, id)
		}
	}
}

func (c *diagnosticCollector) snapshotLocked(s *diagnosticSession, kind string, now time.Time, initial bool) any {
	if c.feed == "dns" {
		return c.dnsSnapshotLocked(s, kind, now, initial)
	}
	frame := diagnosticConnectionsFrame{diagnosticHeader: c.headerLocked(s, kind, now), Live: []DiagnosticConnection{}, Recent: []DiagnosticConnection{},
		Opened: []DiagnosticConnection{}, Traffic: []diagnosticTraffic{}, Closed: []string{}}
	for _, entry := range c.connections {
		if entry.live {
			frame.Live = append(frame.Live, entry.dto)
		}
	}
	sort.Slice(frame.Live, func(i, j int) bool {
		if frame.Live[i].Start == frame.Live[j].Start {
			return frame.Live[i].ID < frame.Live[j].ID
		}
		return frame.Live[i].Start < frame.Live[j].Start
	})
	if !initial {
		for i := range c.recent {
			entry := c.recent[(c.recentHead+i)%len(c.recent)]
			if entry.observed >= s.start {
				frame.Recent = append(frame.Recent, entry.dto)
			}
		}
	}
	return frame
}

func (c *diagnosticCollector) deltaLocked(s *diagnosticSession, now time.Time) any {
	if c.feed == "dns" {
		return c.dnsDeltaLocked(s, now)
	}
	frame := diagnosticConnectionsFrame{diagnosticHeader: c.headerLocked(s, "delta", now), Live: []DiagnosticConnection{}, Recent: []DiagnosticConnection{},
		Opened: []DiagnosticConnection{}, Traffic: []diagnosticTraffic{}, Closed: []string{}}
	for _, event := range s.queue {
		switch event.kind {
		case "opened":
			frame.Opened = append(frame.Opened, event.connection)
		case "traffic":
			frame.Traffic = append(frame.Traffic, event.traffic)
		case "closed":
			frame.Closed = append(frame.Closed, event.id)
		}
	}
	return frame
}
