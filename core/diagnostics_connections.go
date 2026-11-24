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
	dto    DiagnosticConnection
	info   *statistic.TrackerInfo
	live   bool
	recent bool
	closed bool
	stable int
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
	c.liveCount++
	c.liveAtomic.Store(int64(c.liveCount))
	c.connections[entry.dto.ID] = entry
	notifyDiagnosticStats()
}

func (c *diagnosticCollector) openConnection(tracker statistic.Tracker) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return
	}
	entry := c.connections[tracker.ID()]
	if entry != nil && (entry.recent || entry.closed) {
		return
	}
	if entry == nil {
		entry = newDiagnosticConnection(tracker)
		entry.live = true
		c.liveCount++
		c.liveAtomic.Store(int64(c.liveCount))
		c.connections[entry.dto.ID] = entry
	}
	entry.recent = true
	c.appendRecentLocked(entry)
	c.recentAtomic.Store(int64(len(c.recent)))
	notifyDiagnosticStats()
	if len(c.sessions) != 0 {
		c.broadcastLocked(diagnosticEvent{kind: "opened", connection: entry.dto})
		c.scheduleSampleLocked(time.Now())
	}
}

func (c *diagnosticCollector) appendRecentLocked(entry *diagnosticConnectionEntry) {
	if len(c.recent) < diagnosticRecentLimit {
		c.recent = append(c.recent, entry)
		return
	}
	previous := c.recent[c.recentHead]
	previous.recent = false
	c.evicted++
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
	if entry.live {
		c.liveCount--
		c.liveAtomic.Store(int64(c.liveCount))
		notifyDiagnosticStats()
	}
	entry.live = false
	visible := len(c.sessions) != 0
	if visible {
		c.readTrafficLocked(entry, true)
		c.broadcastLocked(diagnosticEvent{kind: "closed", id: entry.dto.ID})
	} else {
		entry.updateTraffic()
		entry.info = nil
	}
	if !entry.recent && !c.initializing {
		entry.info = nil
		delete(c.connections, entry.dto.ID)
	}
	if visible {
		c.scheduleSampleLocked(time.Now())
	}
}

func (c *diagnosticCollector) readTrafficLocked(entry *diagnosticConnectionEntry, force bool) bool {
	changed := entry.updateTraffic()
	if changed || force {
		c.broadcastLocked(diagnosticEvent{kind: "traffic", id: entry.dto.ID,
			traffic: diagnosticTraffic{ID: entry.dto.ID, Upload: entry.dto.Upload, Download: entry.dto.Download}})
	}
	return changed
}

func (entry *diagnosticConnectionEntry) withCurrentTraffic() DiagnosticConnection {
	// 快照不能推进共享采样基线，否则其他已打开的页面会漏掉流量增量。
	dto := entry.dto
	if entry.info != nil {
		dto.Upload = diagnosticCounter(entry.info.UploadTotal.Load())
		dto.Download = diagnosticCounter(entry.info.DownloadTotal.Load())
	}
	return dto
}

func (entry *diagnosticConnectionEntry) updateTraffic() bool {
	if entry.info == nil {
		return false
	}
	upload := diagnosticCounter(entry.info.UploadTotal.Load())
	download := diagnosticCounter(entry.info.DownloadTotal.Load())
	changed := upload != entry.dto.Upload || download != entry.dto.Download
	entry.dto.Upload, entry.dto.Download = upload, download
	return changed
}

func (c *diagnosticCollector) stopSamplingLocked() {
	c.sampleDue = time.Time{}
	for _, entry := range c.recent {
		if !entry.live && entry.info != nil {
			entry.updateTraffic()
			entry.info = nil
		}
	}
	c.kickLocked()
}

func (c *diagnosticCollector) scheduleSampleLocked(now time.Time) {
	if c.feed != "connections" || len(c.sessions) == 0 || !c.sampleDue.IsZero() {
		return
	}
	if c.liveCount == 0 {
		for _, entry := range c.recent {
			if entry.info != nil {
				c.sampleDue = now.Add(time.Second)
				c.kickLocked()
				return
			}
		}
		return
	}
	c.sampleDue = now.Add(time.Second)
	c.kickLocked()
}

func (c *diagnosticCollector) sampleConnectionsLocked(now time.Time) {
	c.sampleDue = time.Time{}
	if len(c.sessions) == 0 {
		return
	}
	for _, entry := range c.connections {
		if entry.info == nil {
			continue
		}
		changed := c.readTrafficLocked(entry, false)
		if entry.live {
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
	if c.liveCount != 0 {
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

func (c *diagnosticCollector) snapshotLocked(s *diagnosticSession, kind string, now time.Time) any {
	if c.feed == "logs" {
		return c.logsFrameLocked(s, kind, now)
	}
	if c.feed == "dns" {
		return c.dnsSnapshotLocked(s, kind, now)
	}
	frame := diagnosticConnectionsFrame{diagnosticHeader: c.headerLocked(s, kind, now), Live: make([]DiagnosticConnection, 0, c.liveCount),
		Recent: make([]DiagnosticConnection, len(c.recent)), Opened: []DiagnosticConnection{},
		Traffic: []diagnosticTraffic{}, Closed: []string{}}
	for _, entry := range c.connections {
		if entry.live {
			frame.Live = append(frame.Live, entry.withCurrentTraffic())
		}
	}
	sort.Slice(frame.Live, func(i, j int) bool {
		if frame.Live[i].Start == frame.Live[j].Start {
			return frame.Live[i].ID < frame.Live[j].ID
		}
		return frame.Live[i].Start < frame.Live[j].Start
	})
	for i := range c.recent {
		frame.Recent[i] = c.recent[(c.recentHead+i)%len(c.recent)].withCurrentTraffic()
	}
	return frame
}

func (c *diagnosticCollector) deltaLocked(s *diagnosticSession, now time.Time) any {
	if c.feed == "logs" {
		return c.logsFrameLocked(s, "delta", now)
	}
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
