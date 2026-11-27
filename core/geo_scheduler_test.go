package main

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
	"github.com/metacubex/mihomo/component/geodata/router"
	"google.golang.org/protobuf/proto"
)

func geoTestMetadata(t *testing.T, home string, id geoResourceID, attempted time.Time) {
	t.Helper()
	geoWrite(t, filepath.Join(home, fmt.Sprintf("geo-%s.json", id)), []byte(fmt.Sprintf(`{"version":1,"managed":true,"lastAttemptAt":%d}`, attempted.UnixMilli())))
}

func TestGeoAutomaticUpdatesOnlyDueResourcesAndRestoresAttemptAfterRestart(t *testing.T) {
	var attempts atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { attempts.Add(1); w.WriteHeader(503) }))
	defer server.Close()
	fixture(t)
	settings := geoTestSettings(server.URL)
	settings.AutoUpdate = true
	settings.IntervalHours = 1
	clock := &geoTestClock{now: time.Now().Truncate(time.Millisecond)}
	for _, id := range geoIDs {
		attempted := clock.Now()
		if id == geoSite {
			attempted = attempted.Add(-2 * time.Hour)
		}
		geoTestMetadata(t, eng.current.HomeDir, id, attempted)
	}
	manager := geoStartFixture(t, settings, clock)
	clock.Advance(10 * time.Second)
	if item := geoItem(t, geoWait(t, manager, geoSite), geoSite); item.Outcome != "failed" {
		t.Fatalf("due item result: %+v", item)
	}
	if attempts.Load() != 1 {
		t.Fatalf("updated non-due resources: %d", attempts.Load())
	}
	eng.mu.Lock()
	manager.closeLocked()
	eng.mu.Unlock()
	manager.wait()
	restartedClock := &geoTestClock{now: clock.Now().Add(time.Minute)}
	geoStartFixture(t, settings, restartedClock)
	restartedClock.Advance(10 * time.Second)
	if attempts.Load() != 1 {
		t.Fatal("restart ignored persisted failed attempt")
	}
	if restartedClock.Pending() != 1 {
		t.Fatal("restart did not schedule next true due time")
	}
}

func TestGeoAutomaticUnchangedWaitsFullInterval(t *testing.T) {
	var attempts atomic.Int32
	payload := geoSiteData(t, "same.example", false)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { attempts.Add(1); _, _ = w.Write(payload) }))
	defer server.Close()
	fixture(t)
	settings := geoTestSettings(server.URL)
	settings.AutoUpdate = true
	settings.IntervalHours = 1
	clock := &geoTestClock{now: time.Now().Truncate(time.Millisecond)}
	for _, id := range geoIDs {
		geoTestMetadata(t, eng.current.HomeDir, id, clock.Now())
	}
	geoTestMetadata(t, eng.current.HomeDir, geoSite, clock.Now().Add(-2*time.Hour))
	path := filepath.Join(eng.current.HomeDir, "geosite.dat")
	geoWrite(t, path, payload)
	old := clock.Now().Add(-2 * time.Hour)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatal(err)
	}
	manager := geoStartFixture(t, settings, clock)
	clock.Advance(10 * time.Second)
	if item := geoItem(t, geoWait(t, manager, geoSite), geoSite); item.Outcome != "unchanged" {
		t.Fatalf("unchanged auto result %+v", item)
	}
	clock.Advance(59 * time.Minute)
	if attempts.Load() != 1 {
		t.Fatal("unchanged content caused automatic retry loop")
	}
}

func TestGeoDisableAutomaticCancelsOnlyAutomaticWork(t *testing.T) {
	for _, automatic := range []bool{true, false} {
		t.Run(fmt.Sprint(automatic), func(t *testing.T) {
			entered, canceled := make(chan struct{}, 1), make(chan struct{}, 1)
			release := make(chan struct{})
			payload := geoSiteData(t, "new.example", false)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				entered <- struct{}{}
				select {
				case <-r.Context().Done():
					canceled <- struct{}{}
				case <-release:
					_, _ = w.Write(payload)
				}
			}))
			defer server.Close()
			fixture(t)
			settings := geoTestSettings(server.URL)
			settings.AutoUpdate = true
			clock := &geoTestClock{now: time.Now().Truncate(time.Millisecond)}
			for _, id := range geoIDs {
				geoTestMetadata(t, eng.current.HomeDir, id, clock.Now())
			}
			manager := geoStartFixture(t, settings, clock)
			eng.mu.Lock()
			_, err := manager.enqueueLocked([]geoResourceID{geoSite, geoIP}, automatic)
			eng.mu.Unlock()
			if err != nil {
				t.Fatal(err)
			}
			receiveProbeSignal(t, entered, "queued Geo task did not start")
			settings.AutoUpdate = false
			settings.Revision = "disabled"
			eng.mu.Lock()
			err = manager.applySettingsLocked(settings)
			eng.mu.Unlock()
			if err != nil {
				t.Fatal(err)
			}
			if automatic {
				receiveProbeSignal(t, canceled, "automatic request was not canceled")
				snapshot := geoWait(t, manager, geoSite, geoIP)
				for _, id := range []geoResourceID{geoSite, geoIP} {
					if geoItem(t, snapshot, id).Outcome != "canceled" {
						t.Fatal("automatic queue did not cancel")
					}
				}
			} else {
				select {
				case <-canceled:
					t.Fatal("manual request canceled by automatic setting")
				default:
				}
				close(release)
				geoWait(t, manager, geoSite, geoIP)
				if item := geoItem(t, manager.snapshot.Load(), geoSite); item.Outcome != "updated" {
					t.Fatalf("manual work canceled: %+v", item)
				}
			}
			if clock.Pending() != 0 {
				t.Fatal("disabled automatic mode retained a timer")
			}
		})
	}
}

func TestGeoInvalidCandidatesAndMetadataWriteFailurePreserveOldFile(t *testing.T) {
	invalidIP, err := proto.Marshal(&router.GeoIPList{Entry: []*router.GeoIP{{CountryCode: "fixture", Cidr: []*router.CIDR{{Ip: []byte{1, 2, 3}, Prefix: 24}}}}})
	if err != nil {
		t.Fatal(err)
	}
	invalidPrefix, _ := proto.Marshal(&router.GeoIPList{Entry: []*router.GeoIP{{CountryCode: "fixture", Cidr: []*router.CIDR{{Ip: []byte{192, 0, 2, 0}, Prefix: 33}}}}})
	invalidRegex, _ := proto.Marshal(&router.GeoSiteList{Entry: []*router.GeoSite{{CountryCode: "fixture", Domain: []*router.Domain{{Type: router.Domain_Regex, Value: "["}}}}})
	invalidType, _ := proto.Marshal(&router.GeoSiteList{Entry: []*router.GeoSite{{CountryCode: "fixture", Domain: []*router.Domain{{Type: 99, Value: "domain.example"}}}}})
	emptyName, _ := proto.Marshal(&router.GeoSiteList{Entry: []*router.GeoSite{{CountryCode: "", Domain: []*router.Domain{{Type: router.Domain_Full, Value: "domain.example"}}}}})
	for _, candidate := range []struct {
		name string
		id   geoResourceID
		data []byte
	}{
		{"cidr", geoIP, invalidIP}, {"prefix", geoIP, invalidPrefix}, {"regexp", geoSite, invalidRegex}, {"domain-type", geoSite, invalidType}, {"name", geoSite, emptyName}, {"mmdb", geoMMDB, []byte("invalid mmap")}, {"asn-country", geoASN, geoReaderBytes(t, countryFixture)},
	} {
		t.Run(candidate.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write(candidate.data) }))
			defer server.Close()
			manager := geoFixture(t, geoTestSettings(server.URL))
			path, err := geoPath(eng.current.HomeDir, candidate.id)
			if err != nil {
				t.Fatal(err)
			}
			old := []byte("old data must survive validation failure")
			geoWrite(t, path, old)
			geoAdmit(t, manager, candidate.id)
			if item := geoItem(t, geoWait(t, manager, candidate.id), candidate.id); item.Outcome != "failed" || item.Error != "geo_invalid_data" {
				t.Fatalf("invalid candidate result %+v", item)
			}
			data, _ := os.ReadFile(path)
			if !bytes.Equal(data, old) {
				t.Fatal("invalid candidate changed old file")
			}
			geoAssertNoTemps(t, eng.current.HomeDir)
		})
	}
	t.Run("metadata-io", func(t *testing.T) {
		payload := geoSiteData(t, "new.example", false)
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write(payload) }))
		defer server.Close()
		fixture(t)
		path := filepath.Join(eng.current.HomeDir, "geosite.dat")
		old := geoSiteData(t, "old.example", false)
		geoWrite(t, path, old)
		if err := os.Mkdir(filepath.Join(eng.current.HomeDir, "geo-geosite.json"), 0700); err != nil {
			t.Fatal(err)
		}
		manager := geoStartFixture(t, geoTestSettings(server.URL), nil)
		geoAdmit(t, manager, geoSite)
		if item := geoItem(t, geoWait(t, manager, geoSite), geoSite); item.Outcome != "failed" || item.Error != "geo_io" {
			t.Fatalf("metadata failure %+v", item)
		}
		data, _ := os.ReadFile(path)
		if !bytes.Equal(data, old) {
			t.Fatal("failed ownership persistence replaced old file")
		}
		geoAssertNoTemps(t, eng.current.HomeDir)
	})
}

func TestGeoRedirectsValidateDestinationAndDoNotForwardControllerCredentials(t *testing.T) {
	var credential atomic.Bool
	payload := geoSiteData(t, "new.example", false)
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "" {
			credential.Store(true)
		}
		_, _ = w.Write(payload)
	}))
	defer target.Close()
	for _, destination := range []string{target.URL + "/data", "ftp://example.invalid/data", "http://user:password@example.invalid/data"} {
		t.Run(fmt.Sprint(len(destination)), func(t *testing.T) {
			redirect := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("Authorization") != "" {
					credential.Store(true)
				}
				http.Redirect(w, r, destination, 302)
			}))
			defer redirect.Close()
			manager := geoFixture(t, geoTestSettings(redirect.URL))
			geoAdmit(t, manager, geoSite)
			item := geoItem(t, geoWait(t, manager, geoSite), geoSite)
			if destination == target.URL+"/data" {
				if item.Outcome != "updated" {
					t.Fatalf("valid redirect %+v", item)
				}
			} else if item.Outcome != "failed" || item.Error != "geo_invalid_url" {
				t.Fatalf("unsafe redirect %+v", item)
			}
			if credential.Load() {
				t.Fatal("controller authorization reached download server")
			}
		})
	}
}
