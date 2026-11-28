package engine

import (
	"bufio"
	"bytes"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	corecfg "github.com/VOD-Studio/ArkClash/core/internal/config"
	"github.com/VOD-Studio/ArkClash/core/internal/geo"
	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
	"github.com/metacubex/mihomo/component/geodata"
	"github.com/metacubex/mihomo/component/geodata/router"
	"github.com/metacubex/mihomo/component/mmdb"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	rules "github.com/metacubex/mihomo/rules/common"
	"github.com/oschwald/maxminddb-golang"
	"google.golang.org/protobuf/proto"
)

type (
	geoResourceID     = geo.ResourceID
	geoSettings       = geo.Settings
	geoURLs           = geo.URLs
	geoManager        = geo.Manager
	geoSnapshot       = geo.Snapshot
	geoResourceStatus = geo.ResourceStatus
	geoTimer          = geo.Timer
)

const (
	geoMMDB          = geo.MMDB
	geoASN           = geo.ASN
	geoIP            = geo.GeoIP
	geoSite          = geo.GeoSite
	geoDownloadLimit = geo.DownloadLimit
	countryFixture   = "GeoIP2-Country-Test.mmdb"
	asnFixture       = "GeoLite2-ASN-Test.mmdb"
)

var geoIDs = geo.IDs

func defaultGeoSettings() geo.Settings                       { return geo.DefaultSettings() }
func geoPath(home string, id geo.ResourceID) (string, error) { return geo.Path(home, id) }
func getGeo(w http.ResponseWriter, r *http.Request)          { geo.HandleGet(eng.geo.Load)(w, r) }
func postGeoSettings(w http.ResponseWriter, r *http.Request) {
	geo.HandlePostSettings(eng.ApplyGeoSettings)(w, r)
}
func postGeoUpdate(w http.ResponseWriter, r *http.Request) { geo.HandlePostUpdate(eng.geo.Load)(w, r) }
func getGeoEvents(w http.ResponseWriter, r *http.Request)  { geo.HandleEvents(eng.geo.Load)(w, r) }

func geoReaderBytes(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "geo", "testdata", "geo", name))
	if err != nil {
		t.Fatal(err)
	}
	expected := map[string]string{
		countryFixture: "9e0a58e6df30dd8d279c9ede70bcb1f19e1bf72f",
		asnFixture:     "16f4b201d9069fd0999bf4988ef3e8977fc4ed8e",
	}[name]
	hash := sha1.New()
	fmt.Fprintf(hash, "blob %d%c", len(data), byte(0))
	hash.Write(data)
	if got := fmt.Sprintf("%x", hash.Sum(nil)); got != expected {
		t.Fatalf("fixture %s blob checksum mismatch", name)
	}
	return data
}

func geoReaderOpen(t *testing.T, path string) *maxminddb.Reader {
	t.Helper()
	reader, err := maxminddb.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := reader.Verify(); err != nil {
		reader.Close()
		t.Fatal(err)
	}
	return reader
}

func geoReaderHome(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	for name, destination := range map[string]string{countryFixture: "geoip.metadb", asnFixture: "ASN.mmdb"} {
		if err := os.WriteFile(filepath.Join(home, destination), geoReaderBytes(t, name), 0600); err != nil {
			t.Fatal(err)
		}
	}
	oldHome, oldIPName, oldASNName := C.Path.HomeDir(), C.GeoipName, C.ASNName
	C.SetHomeDir(home)
	oldIP, oldASN := mmdb.IPInstance(), mmdb.ASNInstance()
	t.Cleanup(func() {
		mmdb.InstallIPReader(oldIP.Reader)
		mmdb.InstallASNReader(oldASN.Reader)
		C.SetHomeDir(oldHome)
		C.GeoipName, C.ASNName = oldIPName, oldASNName
	})
	return home
}

func geoReaderASNQuery(t *testing.T, reader *maxminddb.Reader) (net.IP, string, string) {
	t.Helper()
	networks := reader.Networks()
	for networks.Next() {
		var value mmdb.GeoLite2
		network, err := networks.Network(&value)
		if err != nil {
			t.Fatal(err)
		}
		if value.AutonomousSystemNumber != 0 && value.AutonomousSystemOrganization != "" {
			return network.IP, fmt.Sprint(value.AutonomousSystemNumber), value.AutonomousSystemOrganization
		}
	}
	if err := networks.Err(); err != nil {
		t.Fatal(err)
	}
	t.Fatal("ASN fixture has no populated network")
	return nil, "", ""
}

func geoDiskSettings(t *testing.T, home string, settings geoSettings) {
	t.Helper()
	data, err := json.Marshal(settings)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, "geo-settings.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
}

func geoTestSettings(source string) geoSettings {
	settings := defaultGeoSettings()
	settings.AutoUpdate = false
	settings.URLs = geoURLs{MMDB: source + "/mmdb", ASN: source + "/asn", GeoIP: source + "/geoip", GeoSite: source + "/geosite"}
	settings.Revision = "fixture-settings"
	return settings
}

func geoFixture(t *testing.T, settings geoSettings) *geoManager {
	t.Helper()
	fixture(t)
	geoDiskSettings(t, eng.current.HomeDir, settings)
	return geoStartFixture(t, settings, nil)
}

func geoStartFixture(t *testing.T, settings geoSettings, clock *geoTestClock) *geoManager {
	t.Helper()
	eng.mu.Lock()
	var manager *geoManager
	var err error
	if clock == nil {
		manager, err = geo.NewManager(eng.current.HomeDir, eng.bootID, settings, eng.CommitGeoSwap)
	} else {
		manager, err = geo.NewManagerWithClock(eng.current.HomeDir, eng.bootID, settings, eng.CommitGeoSwap, clock.Now, clock.AfterFunc)
	}
	if err != nil {
		eng.mu.Unlock()
		t.Fatal(err)
	}
	eng.current.Geo = settings
	eng.geo.Store(manager)
	eng.mu.Unlock()
	t.Cleanup(func() {
		manager.Close()
		eng.geo.CompareAndSwap(manager, nil)
		manager.Wait()
	})
	return manager
}

func geoItem(t *testing.T, snapshot *geoSnapshot, id geoResourceID) geoResourceStatus {
	t.Helper()
	for _, item := range snapshot.Items {
		if item.ID == id {
			return item
		}
	}
	t.Fatalf("snapshot omitted resource %s", id)
	return geoResourceStatus{}
}

func geoWait(t *testing.T, manager *geoManager, ids ...geoResourceID) *geoSnapshot {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		snapshot := manager.Snapshot()
		complete := true
		for _, id := range ids {
			item := geoItem(t, snapshot, id)
			complete = complete && item.Phase == "idle" && item.Outcome != "none"
		}
		if complete {
			return snapshot
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("Geo operation did not finish")
	return nil
}

func geoHTTP(t *testing.T, handler http.HandlerFunc, body string) (int, *geoSnapshot) {
	t.Helper()
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/arkclash/geo", strings.NewReader(body))
	handler(recorder, request)
	if recorder.Code < 200 || recorder.Code >= 300 {
		return recorder.Code, nil
	}
	var snapshot geoSnapshot
	if err := json.Unmarshal(recorder.Body.Bytes(), &snapshot); err != nil {
		t.Fatal(err)
	}
	return recorder.Code, &snapshot
}

func geoAdmit(t *testing.T, manager *geoManager, ids ...geoResourceID) *geoSnapshot {
	t.Helper()
	data, _ := json.Marshal(map[string]any{"expectedBootId": manager.Snapshot().BootID, "ids": ids})
	status, snapshot := geoHTTP(t, postGeoUpdate, string(data))
	if status != http.StatusAccepted {
		t.Fatalf("Geo admission status = %d", status)
	}
	return snapshot
}

func geoSiteData(t *testing.T, domain string, includeCN bool) []byte {
	t.Helper()
	entry := &router.GeoSite{CountryCode: "fixture", Domain: []*router.Domain{{Type: router.Domain_Full, Value: domain}}}
	list := &router.GeoSiteList{Entry: []*router.GeoSite{entry}}
	if includeCN {
		list.Entry = append(list.Entry, &router.GeoSite{CountryCode: "CN", Domain: entry.Domain})
	}
	data, err := proto.Marshal(list)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func geoIPData(t *testing.T, address string, includeCN bool) []byte {
	t.Helper()
	entry := &router.GeoIP{CountryCode: "fixture", Cidr: []*router.CIDR{{Ip: net.ParseIP(address).To4(), Prefix: 24}}}
	list := &router.GeoIPList{Entry: []*router.GeoIP{entry}}
	if includeCN {
		list.Entry = append(list.Entry, &router.GeoIP{CountryCode: "CN", Cidr: entry.Cidr})
	}
	data, err := proto.Marshal(list)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func geoWrite(t *testing.T, path string, data []byte) {
	t.Helper()
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
}

func geoAssertNoTemps(t *testing.T, home string) {
	t.Helper()
	paths, err := filepath.Glob(filepath.Join(home, "arkclash-geo-*.tmp"))
	if err != nil || len(paths) != 0 {
		t.Fatalf("Geo temporary files remain: %v (%v)", paths, err)
	}
}

func TestGeoOverridesIgnoreSubscriptionSettings(t *testing.T) {
	raw, err := config.UnmarshalRawConfig([]byte("geo-auto-update: true\ngeo-update-interval: 1\n"))
	if err != nil {
		t.Fatal(err)
	}
	settings := geoTestSettings("https://example.invalid")
	settings.IntervalHours = 37
	corecfg.ApplyOverrides(raw, corecfg.StartOptions{Geo: settings})
	if raw.GeoAutoUpdate || raw.GeoUpdateInterval != 37 || raw.GeoXUrl.Mmdb != settings.URLs.MMDB || raw.GeoXUrl.ASN != settings.URLs.ASN || raw.GeoXUrl.GeoIp != settings.URLs.GeoIP || raw.GeoXUrl.GeoSite != settings.URLs.GeoSite {
		t.Fatalf("subscription Geo settings not overridden: %+v", raw.GeoXUrl)
	}
}

func TestGeoDATUpdateRefreshesExistingRulesWithoutRuntimeRestart(t *testing.T) {
	newSite := geoSiteData(t, "new.example", false)
	newIP := geoIPData(t, "198.51.100.0", false)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/geosite" {
			_, _ = w.Write(newSite)
		} else {
			_, _ = w.Write(newIP)
		}
	}))
	defer server.Close()
	fixture(t)
	home := eng.current.HomeDir
	oldMode, oldLoader := geodata.GeodataMode(), geodata.LoaderName()
	oldIPName, oldSiteName := C.GeoipName, C.GeositeName
	geodata.SetGeodataMode(true)
	geodata.SetLoader("standard")
	C.GeoipName, C.GeositeName = "GeoIP.dat", "geosite.dat"
	geodata.ClearGeoIPCache()
	geodata.ClearGeoSiteCache()
	t.Cleanup(func() {
		geodata.SetGeodataMode(oldMode)
		geodata.SetLoader(oldLoader)
		C.GeoipName, C.GeositeName = oldIPName, oldSiteName
		geodata.ClearGeoIPCache()
		geodata.ClearGeoSiteCache()
	})
	geoWrite(t, filepath.Join(home, "geosite.dat"), geoSiteData(t, "old.example", true))
	geoWrite(t, filepath.Join(home, "GeoIP.dat"), geoIPData(t, "192.0.2.0", true))
	siteRule, err := rules.NewGEOSITE("fixture", "DIRECT")
	if err != nil {
		t.Fatal(err)
	}
	ipRule, err := rules.NewGEOIP("fixture", "DIRECT", false, true)
	if err != nil {
		t.Fatal(err)
	}
	if !siteRule.MatchDomain("old.example") || siteRule.MatchDomain("new.example") || !ipRule.MatchIp(netip.MustParseAddr("192.0.2.1")) {
		t.Fatal("initial rules did not use old data")
	}
	settings := geoTestSettings(server.URL)
	geoDiskSettings(t, home, settings)
	manager := geoStartFixture(t, settings, nil)
	boot, revision, configRevision, tun := eng.bootID, eng.revision, eng.configRevision, eng.tun
	geoAdmit(t, manager, geoSite, geoIP)
	snapshot := geoWait(t, manager, geoSite, geoIP)
	for _, id := range []geoResourceID{geoSite, geoIP} {
		if item := geoItem(t, snapshot, id); item.Outcome != "updated" {
			t.Fatalf("DAT result %s: %+v", id, item)
		}
	}
	if !siteRule.MatchDomain("new.example") || siteRule.MatchDomain("old.example") || !ipRule.MatchIp(netip.MustParseAddr("198.51.100.1")) || ipRule.MatchIp(netip.MustParseAddr("192.0.2.1")) {
		t.Fatal("existing rules retained stale Geo matchers")
	}
	eng.mu.Lock()
	defer eng.mu.Unlock()
	if eng.bootID != boot || eng.configRevision != configRevision || eng.tun != tun || eng.revision <= revision {
		t.Fatal("Geo update restarted forwarding or failed to invalidate runtime probes")
	}
	geoAssertNoTemps(t, home)
}

func TestGeoDownloadFailuresPreserveDataAndTimestamp(t *testing.T) {
	valid := geoSiteData(t, "new.example", false)
	for _, mode := range []string{"invalid", "truncated", "empty", "oversize", "503", "timeout"} {
		t.Run(mode, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch mode {
				case "invalid":
					_, _ = w.Write([]byte("invalid protobuf"))
				case "truncated":
					w.Header().Set("Content-Length", fmt.Sprint(len(valid)+100))
					_, _ = w.Write(valid)
				case "empty":
				case "503":
					w.WriteHeader(503)
				case "timeout":
					<-r.Context().Done()
				case "oversize":
					chunk := make([]byte, 32<<10)
					for remaining := int64(geoDownloadLimit) + 1; remaining > 0; {
						n := min(int64(len(chunk)), remaining)
						if _, err := w.Write(chunk[:n]); err != nil {
							return
						}
						remaining -= n
					}
				}
			}))
			defer server.Close()
			manager := geoFixture(t, geoTestSettings(server.URL))
			path := filepath.Join(eng.current.HomeDir, "geosite.dat")
			old := geoSiteData(t, "old.example", true)
			geoWrite(t, path, old)
			stamp := time.Now().Add(-2 * time.Hour).Truncate(time.Millisecond)
			if err := os.Chtimes(path, stamp, stamp); err != nil {
				t.Fatal(err)
			}
			oldTimeout := geo.DownloadTimeout
			if mode == "timeout" {
				geo.DownloadTimeout = 40 * time.Millisecond
			}
			defer func() { geo.DownloadTimeout = oldTimeout }()
			geoAdmit(t, manager, geoSite)
			item := geoItem(t, geoWait(t, manager, geoSite), geoSite)
			if item.Outcome != "failed" || item.Error == "" {
				t.Fatalf("failure result %+v", item)
			}
			if mode == "503" && item.Error != "geo_http_503" {
				t.Fatalf("HTTP error not stable: %s", item.Error)
			}
			if mode == "timeout" && item.Error != "geo_timeout" {
				t.Fatalf("timeout error not stable: %s", item.Error)
			}
			data, err := os.ReadFile(path)
			if err != nil || sha256.Sum256(data) != sha256.Sum256(old) {
				t.Fatal("failed Geo update replaced old data")
			}
			stat, err := os.Stat(path)
			if err != nil || !stat.ModTime().Equal(stamp) {
				t.Fatal("failed Geo update changed mtime")
			}
			geoAssertNoTemps(t, eng.current.HomeDir)
		})
	}
}

func TestGeoUnchangedValidatesAndPreservesModificationTime(t *testing.T) {
	payload := geoSiteData(t, "old.example", false)
	var response atomic.Pointer[[]byte]
	response.Store(&payload)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write(*response.Load()) }))
	defer server.Close()
	manager := geoFixture(t, geoTestSettings(server.URL))
	path := filepath.Join(eng.current.HomeDir, "geosite.dat")
	geoWrite(t, path, payload)
	stamp := time.Now().Add(-time.Hour).Truncate(time.Millisecond)
	if err := os.Chtimes(path, stamp, stamp); err != nil {
		t.Fatal(err)
	}
	runtimeBefore := eng.Status().Revision
	geoAdmit(t, manager, geoSite)
	item := geoItem(t, geoWait(t, manager, geoSite), geoSite)
	stat, _ := os.Stat(path)
	if item.Outcome != "unchanged" || !stat.ModTime().Equal(stamp) {
		t.Fatalf("identical file changed: %+v", item)
	}
	if eng.Status().Revision != runtimeBefore {
		t.Fatal("unchanged content invalidated runtime generation")
	}
	var metadata struct {
		Version       int
		Managed       bool
		LastAttemptAt int64
	}
	data, err := os.ReadFile(filepath.Join(eng.current.HomeDir, "geo-geosite.json"))
	if err != nil || json.Unmarshal(data, &metadata) != nil || !metadata.Managed || metadata.LastAttemptAt <= stamp.UnixMilli() {
		t.Fatal("unchanged update omitted durable attempt/ownership")
	}
	geoAssertNoTemps(t, eng.current.HomeDir)
	invalid := []byte("invalid existing bytes")
	response.Store(&invalid)
	geoWrite(t, path, invalid)
	geoAdmit(t, manager, geoSite)
	if item := geoItem(t, geoWait(t, manager, geoSite), geoSite); item.Outcome != "failed" || item.Error != "geo_invalid_data" {
		t.Fatalf("identical invalid content bypassed verification: %+v", item)
	}
}

func TestGeoMMDBCandidateSwitchRetainsActiveReaders(t *testing.T) {
	fixtureHome := geoReaderHome(t)
	country := geoReaderBytes(t, countryFixture)
	fixtureReader := geoReaderOpen(t, filepath.Join(fixtureHome, "geoip.metadb"))
	dataOffset := int(fixtureReader.Metadata.NodeCount)*int(fixtureReader.Metadata.RecordSize)/4 + 16
	_ = fixtureReader.Close()
	// 只替换数据区里定长的国家代码，不能修改搜索树中恰好相同的指针字节。
	changed := bytes.Clone(country)
	copy(changed[dataOffset:], bytes.ReplaceAll(country[dataOffset:], []byte{0x42, 'G', 'B'}, []byte{0x42, 'Z', 'Z'}))
	if bytes.Equal(changed, country) {
		t.Fatal("country fixture has no encoded GB record")
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/asn" {
			_, _ = w.Write(geoReaderBytes(t, asnFixture))
		} else {
			_, _ = w.Write(changed)
		}
	}))
	defer server.Close()
	manager := geoFixture(t, geoTestSettings(server.URL))
	home := eng.current.HomeDir
	geoWrite(t, filepath.Join(home, "geoip.metadb"), country)
	candidate := geoReaderOpen(t, filepath.Join(home, "geoip.metadb"))
	mmdb.InstallIPReader(candidate)
	old := mmdb.IPInstance()
	query := net.ParseIP("81.2.69.142")
	if got := old.LookupCode(query); len(got) != 1 || got[0] != "gb" {
		t.Fatal("country fixture mismatch")
	}
	geoAdmit(t, manager, geoMMDB, geoASN)
	snapshot := geoWait(t, manager, geoMMDB, geoASN)
	for _, id := range []geoResourceID{geoMMDB, geoASN} {
		if item := geoItem(t, snapshot, id); item.Outcome != "updated" {
			t.Fatalf("MMDB install %s: %+v", id, item)
		}
	}
	if got := old.LookupCode(query); len(got) != 1 || got[0] != "gb" {
		t.Fatal("old mmap was closed or modified")
	}
	if got := mmdb.IPInstance().LookupCode(query); len(got) != 1 || got[0] != "zz" {
		t.Fatalf("new mmap not installed: %v", got)
	}
	asnIP, wantASN, wantOrg := geoReaderASNQuery(t, mmdb.ASNInstance().Reader)
	if number, org := mmdb.ASNInstance().LookupASN(asnIP); number != wantASN || org != wantOrg {
		t.Fatal("installed ASN unreadable")
	}
	geoAssertNoTemps(t, home)
}

func TestGeoQueueDeduplicatesAndKeepsControllerResponsive(t *testing.T) {
	entered, release := make(chan struct{}, 1), make(chan struct{})
	var total atomic.Int32
	var live, peak atomic.Int32
	geoReaderHome(t)
	payload := geoSiteData(t, "new.example", false)
	country, asn := geoReaderBytes(t, countryFixture), geoReaderBytes(t, asnFixture)
	ip := geoIPData(t, "198.51.100.0", false)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := live.Add(1)
		defer live.Add(-1)
		for previous := peak.Load(); n > previous && !peak.CompareAndSwap(previous, n); previous = peak.Load() {
		}
		if total.Add(1) == 1 {
			entered <- struct{}{}
			select {
			case <-release:
			case <-r.Context().Done():
				return
			}
		}
		switch r.URL.Path {
		case "/mmdb":
			_, _ = w.Write(country)
		case "/asn":
			_, _ = w.Write(asn)
		case "/geoip":
			_, _ = w.Write(ip)
		default:
			_, _ = w.Write(payload)
		}
	}))
	t.Cleanup(server.Close)
	manager := geoFixture(t, geoTestSettings(server.URL))
	first := geoAdmit(t, manager, geoSite, geoMMDB, geoIP, geoASN)
	receiveProbeSignal(t, entered, "Geo download did not start")
	second := geoAdmit(t, manager, geoSite, geoMMDB, geoIP, geoSite)
	for _, id := range geoIDs {
		if geoItem(t, first, id).OperationID != geoItem(t, second, id).OperationID {
			t.Fatal("duplicate admitted another operation")
		}
	}
	controller := make(chan struct{})
	go func() {
		getStatus(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/arkclash/status", nil))
		getGeo(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/arkclash/geo", nil))
		close(controller)
	}()
	receiveProbeSignal(t, controller, "controller blocked behind download")
	close(release)
	geoWait(t, manager, geoIDs...)
	if total.Load() != 4 || peak.Load() != 1 {
		t.Fatalf("download count=%d concurrency=%d", total.Load(), peak.Load())
	}
}

func TestGeoStrictHTTPAndSettingsRevision(t *testing.T) {
	manager := geoFixture(t, defaultGeoSettings())
	boot := manager.Snapshot().BootID
	for _, body := range []string{`{}`, `{"expectedBootId":"x","ids":["unknown"]}`, fmt.Sprintf(`{"expectedBootId":%q,"ids":[]}`, boot), fmt.Sprintf(`{"expectedBootId":%q,"ids":["mmdb"],"path":"/tmp/escape"}`, boot), strings.Repeat(" ", 16<<10) + "{}", `{} {}`} {
		if status, _ := geoHTTP(t, postGeoUpdate, body); status != 400 {
			t.Fatalf("invalid request status=%d", status)
		}
	}
	if status, _ := geoHTTP(t, postGeoUpdate, `{"expectedBootId":"old-boot","ids":["mmdb"]}`); status != 409 {
		t.Fatalf("stale boot status=%d", status)
	}
	settings := defaultGeoSettings()
	settings.Revision = "new-revision"
	settings.IntervalHours = 48
	geoDiskSettings(t, eng.current.HomeDir, settings)
	if status, _ := geoHTTP(t, postGeoSettings, fmt.Sprintf(`{"expectedBootId":%q,"revision":"old-revision"}`, boot)); status != 409 {
		t.Fatalf("stale settings status=%d", status)
	}
	status, snapshot := geoHTTP(t, postGeoSettings, fmt.Sprintf(`{"expectedBootId":%q,"revision":%q}`, boot, settings.Revision))
	if status != 200 || snapshot.SettingsRevision != settings.Revision || eng.current.Geo.IntervalHours != 48 {
		t.Fatal("saved settings not applied")
	}
	manager.Close()
	manager.Wait()
	if status, _ := geoHTTP(t, postGeoUpdate, fmt.Sprintf(`{"expectedBootId":%q,"ids":["mmdb"]}`, boot)); status != 503 {
		t.Fatalf("stopped manager accepted operation: %d", status)
	}
}

func TestGeoURLChangeAndStopCancelActualRequest(t *testing.T) {
	for _, action := range []string{"url", "stop"} {
		t.Run(action, func(t *testing.T) {
			entered, canceled := make(chan struct{}, 1), make(chan struct{}, 1)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				entered <- struct{}{}
				<-r.Context().Done()
				canceled <- struct{}{}
			}))
			defer server.Close()
			settings := geoTestSettings(server.URL)
			manager := geoFixture(t, settings)
			path := filepath.Join(eng.current.HomeDir, "geosite.dat")
			old := geoSiteData(t, "old.example", false)
			geoWrite(t, path, old)
			geoAdmit(t, manager, geoSite)
			receiveProbeSignal(t, entered, "download did not enter server")
			if action == "url" {
				settings.URLs.GeoSite = server.URL + "/changed"
				settings.Revision = "changed"
				geoDiskSettings(t, eng.current.HomeDir, settings)
				status, _ := geoHTTP(t, postGeoSettings, fmt.Sprintf(`{"expectedBootId":%q,"revision":"changed"}`, manager.Snapshot().BootID))
				if status != 200 {
					t.Fatal("URL change rejected")
				}
			} else {
				manager.Close()
				manager.Wait()
			}
			receiveProbeSignal(t, canceled, "actual HTTP request did not receive cancellation")
			if action == "url" {
				if item := geoItem(t, geoWait(t, manager, geoSite), geoSite); item.Outcome != "canceled" {
					t.Fatalf("stale URL result %+v", item)
				}
			}
			data, _ := os.ReadFile(path)
			if !bytes.Equal(data, old) {
				t.Fatal("canceled download replaced old data")
			}
			geoAssertNoTemps(t, eng.current.HomeDir)
		})
	}
}

func TestGeoMetadataCorruptionProtectsAutomaticUpdatesAndManualRepairs(t *testing.T) {
	var attempts atomic.Int32
	payload := geoSiteData(t, "new.example", false)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { attempts.Add(1); _, _ = w.Write(payload) }))
	defer server.Close()
	fixture(t)
	settings := geoTestSettings(server.URL)
	geoWrite(t, filepath.Join(eng.current.HomeDir, "geo-geosite.json"), []byte("corrupt"))
	manager := geoStartFixture(t, settings, nil)
	if item := geoItem(t, manager.Snapshot(), geoSite); item.Error != "geo_metadata_invalid" {
		t.Fatal("corrupt metadata hidden")
	}
	_, err := manager.Enqueue([]geoResourceID{geoSite}, true)
	if err != nil {
		t.Fatal(err)
	}
	if attempts.Load() != 0 {
		t.Fatal("automatic update bypassed corrupt metadata")
	}
	geoAdmit(t, manager, geoSite)
	if item := geoItem(t, geoWait(t, manager, geoSite), geoSite); item.Outcome != "updated" || attempts.Load() != 1 {
		t.Fatalf("manual metadata repair %+v", item)
	}
}

func geoWebSocket(t *testing.T, address string) (net.Conn, *bufio.Reader) {
	t.Helper()
	connection, err := net.Dial("tcp", strings.TrimPrefix(address, "http://"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = connection.Close() })
	_ = connection.SetDeadline(time.Now().Add(3 * time.Second))
	_, err = fmt.Fprintf(connection, "GET /arkclash/geo/events HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: Z2VvLXJlc291cmNlLXRlc3Q=\r\n\r\n")
	if err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(connection)
	line, err := reader.ReadString('\n')
	if err != nil || !strings.Contains(line, "101") {
		t.Fatalf("Geo websocket handshake: %s %v", line, err)
	}
	for {
		line, err = reader.ReadString('\n')
		if err != nil {
			t.Fatal(err)
		}
		if line == "\r\n" {
			break
		}
	}
	return connection, reader
}

func geoReadFrame(t *testing.T, reader *bufio.Reader) *geoSnapshot {
	t.Helper()
	header := make([]byte, 2)
	if _, err := io.ReadFull(reader, header); err != nil {
		t.Fatal(err)
	}
	if header[0] != 0x81 || header[1]&0x80 != 0 {
		t.Fatal("unexpected Geo websocket frame")
	}
	length := uint64(header[1] & 0x7f)
	if length == 126 {
		var size uint16
		if err := binary.Read(reader, binary.BigEndian, &size); err != nil {
			t.Fatal(err)
		}
		length = uint64(size)
	} else if length == 127 {
		if err := binary.Read(reader, binary.BigEndian, &length); err != nil {
			t.Fatal(err)
		}
	}
	if length > 64<<10 {
		t.Fatal("oversized Geo snapshot")
	}
	body := make([]byte, int(length))
	if _, err := io.ReadFull(reader, body); err != nil {
		t.Fatal(err)
	}
	var event struct {
		Type     string
		Snapshot geoSnapshot
	}
	if err := json.Unmarshal(body, &event); err != nil || event.Type != "geo" {
		t.Fatal("invalid Geo event")
	}
	return &event.Snapshot
}

func TestGeoWebSocketInitialAndReconnectDeliverFinalState(t *testing.T) {
	payload := geoSiteData(t, "new.example", false)
	finish := make(chan struct{})
	release := sync.OnceFunc(func() { close(finish) })
	source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", fmt.Sprint(len(payload)))
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		select {
		case <-finish:
			_, _ = w.Write(payload)
		case <-r.Context().Done():
		}
	}))
	defer source.Close()
	defer release()
	manager := geoFixture(t, geoTestSettings(source.URL))
	events := httptest.NewServer(http.HandlerFunc(getGeoEvents))
	defer events.Close()
	connection, reader := geoWebSocket(t, events.URL)
	initial := geoReadFrame(t, reader)
	if initial.BootID != manager.Snapshot().BootID {
		t.Fatal("initial snapshot omitted current boot")
	}
	geoAdmit(t, manager, geoSite)
	for {
		item := geoItem(t, geoReadFrame(t, reader), geoSite)
		if item.Phase == "updating" && item.TotalBytes == int64(len(payload)) {
			if item.ReceivedBytes != 0 {
				t.Fatal("download reported bytes before reading the body")
			}
			break
		}
	}
	release()
	terminal := geoWait(t, manager, geoSite)
	latest := initial
	for latest.Revision < terminal.Revision {
		latest = geoReadFrame(t, reader)
	}
	if item := geoItem(t, latest, geoSite); item.Phase != "idle" || item.Outcome != "updated" ||
		item.ReceivedBytes != int64(len(payload)) || item.TotalBytes != int64(len(payload)) {
		t.Fatalf("final event omitted download result: %+v", item)
	}
	_ = connection.Close()
	_, reader = geoWebSocket(t, events.URL)
	recovered := geoReadFrame(t, reader)
	if recovered.Revision < terminal.Revision || geoItem(t, recovered, geoSite).Phase != "idle" {
		t.Fatal("reconnect replayed stale busy state")
	}
}

type geoTestTimer struct {
	clock    *geoTestClock
	at       time.Time
	callback func()
	stopped  bool
}

func (timer *geoTestTimer) Stop() bool {
	timer.clock.mu.Lock()
	defer timer.clock.mu.Unlock()
	was := !timer.stopped
	timer.stopped = true
	return was
}

type geoTestClock struct {
	mu     sync.Mutex
	now    time.Time
	timers []*geoTestTimer
}

func (clock *geoTestClock) Now() time.Time {
	clock.mu.Lock()
	defer clock.mu.Unlock()
	return clock.now
}
func (clock *geoTestClock) AfterFunc(delay time.Duration, callback func()) geoTimer {
	clock.mu.Lock()
	defer clock.mu.Unlock()
	timer := &geoTestTimer{clock: clock, at: clock.now.Add(delay), callback: callback}
	clock.timers = append(clock.timers, timer)
	return timer
}
func (clock *geoTestClock) Advance(elapsed time.Duration) {
	clock.mu.Lock()
	clock.now = clock.now.Add(elapsed)
	var callbacks []func()
	for _, timer := range clock.timers {
		if !timer.stopped && !timer.at.After(clock.now) {
			timer.stopped = true
			callbacks = append(callbacks, timer.callback)
		}
	}
	clock.mu.Unlock()
	for _, callback := range callbacks {
		callback()
	}
}
func (clock *geoTestClock) Pending() int {
	clock.mu.Lock()
	defer clock.mu.Unlock()
	count := 0
	for _, timer := range clock.timers {
		if !timer.stopped {
			count++
		}
	}
	return count
}

func TestGeoAutomaticTimerStartupGuardAndAttemptBackoff(t *testing.T) {
	var attempts atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { attempts.Add(1); w.WriteHeader(503) }))
	defer server.Close()
	fixture(t)
	settings := geoTestSettings(server.URL)
	clock := &geoTestClock{now: time.Now().Truncate(time.Millisecond)}
	manager := geoStartFixture(t, settings, clock)
	if clock.Pending() != 0 {
		t.Fatal("automatic updates disabled but timer remains")
	}
	settings.AutoUpdate = true
	settings.IntervalHours = 1
	settings.Revision = "auto"
	err := manager.ApplySettings(settings)
	if err != nil {
		t.Fatal(err)
	}
	if clock.Pending() != 1 {
		t.Fatal("automatic update did not install one timer")
	}
	clock.Advance(9 * time.Second)
	if attempts.Load() != 0 {
		t.Fatal("automatic update ignored startup protection")
	}
	clock.Advance(time.Second)
	geoWait(t, manager, geoIDs...)
	if attempts.Load() != 4 {
		t.Fatalf("due resources attempted=%d", attempts.Load())
	}
	clock.Advance(59 * time.Minute)
	if attempts.Load() != 4 {
		t.Fatal("failure retried before full interval")
	}
	settings.AutoUpdate = false
	err = manager.ApplySettings(settings)
	if err != nil {
		t.Fatal(err)
	}
	if clock.Pending() != 0 {
		t.Fatal("disabled automatic update retained timer")
	}
}

func TestGeoTemporaryCleanupOnlyRemovesOwnedNames(t *testing.T) {
	fixture(t)
	home := eng.current.HomeDir
	for _, name := range []string{"arkclash-geo-mmdb-crash.tmp", "arkclash-geo-geosite-crash.tmp", "other.tmp", "arkclash-geo-unknown-crash.tmp", "arkclash-geo-mmdb-keep.txt"} {
		geoWrite(t, filepath.Join(home, name), []byte("fixture"))
	}
	geoStartFixture(t, defaultGeoSettings(), nil)
	for _, name := range []string{"other.tmp", "arkclash-geo-unknown-crash.tmp", "arkclash-geo-mmdb-keep.txt"} {
		if _, err := os.Stat(filepath.Join(home, name)); err != nil {
			t.Fatal("startup cleanup removed unrelated file")
		}
	}
	for _, name := range []string{"arkclash-geo-mmdb-crash.tmp", "arkclash-geo-geosite-crash.tmp"} {
		if _, err := os.Stat(filepath.Join(home, name)); !os.IsNotExist(err) {
			t.Fatal("owned crash temporary file survived")
		}
	}
}

func TestGeoStopWaitsForActualRuleDialCleanup(t *testing.T) {
	fixture(t)
	address, entered, closed, active := blockingProbeProxy(t)
	installProbeConfig(t, "mode: rule\nlog-level: silent\nproxies:\n"+probeProxyConfig(t, "Slow", address)+"rules: ['MATCH,Slow']\n")
	settings := geoTestSettings("http://127.0.0.1:1")
	manager := geoStartFixture(t, settings, nil)
	geoAdmit(t, manager, geoSite)
	receiveProbeSignal(t, entered, "Geo request never entered real proxy dial")
	manager.Close()
	joined := make(chan struct{})
	go func() { manager.Wait(); close(joined) }()
	receiveProbeSignal(t, closed, "Geo stop did not cancel actual proxy dial")
	receiveProbeSignal(t, joined, "Geo stop deadlocked waiting for worker")
	if active.Load() != 0 {
		t.Fatal("Geo worker released before actual dial closed")
	}
}

func TestGeoConcurrentUpdatesSettingsAndReload(t *testing.T) {
	payloadA := geoSiteData(t, "a.example", false)
	payloadB := geoSiteData(t, "b.example", false)
	var toggle atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if toggle.Swap(!toggle.Load()) {
			_, _ = w.Write(payloadA)
		} else {
			_, _ = w.Write(payloadB)
		}
	}))
	defer server.Close()

	settings := geoTestSettings(server.URL)
	manager := geoFixture(t, settings)
	home := eng.current.HomeDir
	boot := manager.Snapshot().BootID
	profilePath := filepath.Join(home, "profiles", "concurrent-geo.yaml")
	if err := os.MkdirAll(filepath.Dir(profilePath), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(profilePath, []byte("mode: rule\nlog-level: silent\nrules:\n  - MATCH,DIRECT\n"), 0600); err != nil {
		t.Fatal(err)
	}

	var wg sync.WaitGroup
	wg.Add(4)
	go func() {
		defer wg.Done()
		for i := range 12 {
			body, _ := json.Marshal(map[string]any{"expectedBootId": boot, "ids": []geoResourceID{geoSite}})
			recorder := httptest.NewRecorder()
			postGeoUpdate(recorder, httptest.NewRequest(http.MethodPost, "/arkclash/geo/update", strings.NewReader(string(body))))
			if i%3 == 0 {
				time.Sleep(time.Millisecond)
			}
		}
	}()
	go func() {
		defer wg.Done()
		for i := range 10 {
			next := settings
			next.Revision = fmt.Sprintf("rev-%d", i)
			next.IntervalHours = 12 + i
			data, _ := json.Marshal(next)
			_ = os.WriteFile(filepath.Join(home, "geo-settings.json"), data, 0600)
			body := fmt.Sprintf(`{"expectedBootId":%q,"revision":%q}`, boot, next.Revision)
			recorder := httptest.NewRecorder()
			postGeoSettings(recorder, httptest.NewRequest(http.MethodPost, "/arkclash/geo/settings", strings.NewReader(body)))
			time.Sleep(time.Millisecond)
		}
	}()
	go func() {
		defer wg.Done()
		for range 20 {
			recorder := httptest.NewRecorder()
			getGeo(recorder, httptest.NewRequest(http.MethodGet, "/arkclash/geo", nil))
			time.Sleep(time.Millisecond)
		}
	}()
	go func() {
		defer wg.Done()
		for range 20 {
			_ = eng.withState(func(tx *stateTx) error {
				eng.publishRuntimeLocked()
				return nil
			})
			_, _ = eng.ConfigSpec()
			_ = eng.View()
			time.Sleep(time.Millisecond)
		}
	}()
	wg.Wait()
	// 等待队列排空后再执行热切换，避免上游 mihomo 的 ApplyConfig 与在途 Direct.DialContext 竞态。
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if geoItem(t, manager.Snapshot(), geoSite).Phase == "idle" {
			break
		}
		time.Sleep(time.Millisecond)
	}
	if err := reload(profilePath, "concurrent-geo", nil); err != nil {
		t.Fatalf("reload after concurrent geo updates failed: %v", err)
	}
	geoAssertNoTemps(t, home)
}
