package main

import (
	"encoding/json"
	"net/netip"
	"os"
	"path/filepath"
	"testing"

	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

func TestDiagnosticsReloadKeepsSessionOnParseFailure(t *testing.T) {
	fixture(t)
	session, status, err := subscribeDiagnostics("connections", runtimeBootID, runtimeConfigRevision)
	if err != nil {
		t.Fatalf("subscribe status=%d err=%v", status, err)
	}
	go func() { <-session.done; close(session.workerDone) }()
	defer session.close()
	oldRevision := runtimeConfigRevision
	path := filepath.Join(current.HomeDir, "profiles", "next.yaml")
	if err := os.WriteFile(path, []byte("rules: [\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := reload(path, "next", new("fixture")); err == nil {
		t.Fatal("invalid config accepted")
	}
	select {
	case <-session.done:
		t.Fatal("failed parse stopped existing observation session")
	default:
	}
	if runtimeConfigRevision != oldRevision || current.Profile != "fixture" {
		t.Fatal("failed parse changed runtime identity")
	}
	if err := os.WriteFile(path, []byte("mode: direct\nlog-level: silent\nrules: ['MATCH,DIRECT']\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := reload(path, "next", new("fixture")); err != nil {
		t.Fatal(err)
	}
	select {
	case <-session.done:
	default:
		t.Fatal("successful reload retained old observation session")
	}
	if runtimeConfigRevision != oldRevision+1 || current.Profile != "next" {
		t.Fatal("successful reload did not advance configuration identity")
	}
}

type lifecycleDiagnosticConn struct {
	C.Conn
	chain C.Chain
}

func (c *lifecycleDiagnosticConn) Close() error              { return nil }
func (c *lifecycleDiagnosticConn) RemoteDestination() string { return "fixture.diag.test:443" }
func (c *lifecycleDiagnosticConn) Chains() C.Chain           { return c.chain }
func (c *lifecycleDiagnosticConn) ProviderChains() C.Chain   { return nil }

func TestDiagnosticsMetadataSnapshotExcludesPrivateTrackerFields(t *testing.T) {
	fixture(t)
	metadata := &C.Metadata{
		NetWork: C.TCP, Host: "fixture.diag.test", DstIP: netip.MustParseAddr("2001:db8::1"),
		SrcPort: 54321, DstPort: 443, SrcGeoIP: []string{"initial"},
		InUser: "must-not-export", Process: "must-not-export", Uid: 1234,
	}
	conn := &lifecycleDiagnosticConn{chain: C.Chain{"DIRECT"}}
	tracker := statistic.NewTCPTracker(conn, statistic.DefaultManager, metadata, nil, 12, 34, false)
	defer tracker.Close()
	session, status, err := subscribeDiagnostics("connections", runtimeBootID, runtimeConfigRevision)
	if err != nil {
		t.Fatalf("subscribe status=%d err=%v", status, err)
	}
	go func() { <-session.done; close(session.workerDone) }()
	defer session.close()
	metadata.SrcGeoIP[0] = "mutated-after-ingress"
	conn.chain[0] = "mutated-after-ingress"
	data, err := json.Marshal(session.nextFrame())
	if err != nil {
		t.Fatal(err)
	}
	var frame struct {
		Live []struct {
			ID             string         `json:"id"`
			Metadata       map[string]any `json:"metadata"`
			Chains         []string       `json:"chains"`
			ProviderChains []string       `json:"providerChains"`
			Upload         int64          `json:"upload"`
			Download       int64          `json:"download"`
		} `json:"live"`
		Recent []any `json:"recent"`
	}
	if err := json.Unmarshal(data, &frame); err != nil {
		t.Fatal(err)
	}
	if len(frame.Live) == 0 || frame.Recent == nil || len(frame.Recent) != 0 {
		t.Fatalf("invalid baseline frame: %s", data)
	}
	record := frame.Live[0]
	found := false
	for _, candidate := range frame.Live {
		if candidate.ID == tracker.ID() {
			record = candidate
			found = true
			break
		}
	}
	if !found {
		t.Fatal("baseline omitted existing tracker")
	}
	for _, field := range []string{"uid", "process", "processPath", "inboundUser", "rawSrcAddr", "rawDstAddr"} {
		if _, leaked := record.Metadata[field]; leaked {
			t.Fatalf("exported private field %s", field)
		}
	}
	if record.Metadata["sourceIP"] != "" || record.Metadata["destinationIP"] != "2001:db8::1" ||
		record.Metadata["sourcePort"] != "54321" || record.Metadata["destinationPort"] != "443" {
		t.Fatalf("wrong address/port encoding: %+v", record.Metadata)
	}
	geo, ok := record.Metadata["sourceGeoIP"].([]any)
	if !ok || len(geo) != 1 || geo[0] != "initial" || len(record.Chains) != 1 || record.Chains[0] != "DIRECT" {
		t.Fatal("metadata snapshot retained mutable tracker slices")
	}
	destinationGeo, ok := record.Metadata["destinationGeoIP"].([]any)
	if !ok || destinationGeo == nil || record.ProviderChains == nil {
		t.Fatal("missing arrays encoded as null")
	}
	if record.Upload != 12 || record.Download != 34 {
		t.Fatal("lost initial cumulative traffic")
	}
}
