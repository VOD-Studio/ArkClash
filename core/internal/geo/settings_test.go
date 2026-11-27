package geo

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestGeoSettingsAndFixedPathContract(t *testing.T) {
	home := t.TempDir()
	writeDisk := func(settings Settings) {
		t.Helper()
		data, err := json.Marshal(settings)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(home, "geo-settings.json"), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	defaults, err := ReadSettings(home)
	if err != nil || defaults.Revision != "default" || !defaults.AutoUpdate || defaults.IntervalHours != 24 {
		t.Fatalf("missing settings: %+v %v", defaults, err)
	}
	disabled := defaults
	disabled.AutoUpdate = false
	writeDisk(disabled)
	if saved, err := ReadSettings(home); err != nil || saved.AutoUpdate {
		t.Fatalf("saved Geo preference: %+v %v", saved, err)
	}
	for _, source := range []string{"", "ftp://example.com/a", "https://user:password@example.com/a", "http:///missing", strings.Repeat("x", 2049)} {
		settings := defaults
		settings.URLs.MMDB = source
		writeDisk(settings)
		if _, err := ReadSettings(home); err == nil {
			t.Fatal("invalid Geo URL accepted")
		}
	}
	for _, body := range []string{"{", "null", `{"version":2}`, `{"version":1}`, `{} {}`, `{"version":1,"revision":"a","autoUpdate":false,"intervalHours":0,"urls":{}}`} {
		if err := os.WriteFile(filepath.Join(home, "geo-settings.json"), []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := ReadSettings(home); err == nil {
			t.Fatal("invalid settings accepted")
		}
	}
	for _, hours := range []int{0, -1, 8761} {
		settings := defaults
		settings.IntervalHours = hours
		writeDisk(settings)
		if _, err := ReadSettings(home); err == nil {
			t.Fatal("invalid interval accepted")
		}
	}
	unsupported := defaults
	unsupported.Version = 2
	writeDisk(unsupported)
	if _, err := ReadSettings(home); err == nil {
		t.Fatal("unsupported version accepted")
	}
	writeDisk(defaults)
	for _, name := range []string{"geoip.metadb", "geoip.db", "Country.mmdb", "gEoSiTe.DaT", "aSn.MmDb", "gEOiP.DAT"} {
		if err := os.WriteFile(filepath.Join(home, name), []byte("fixture"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	for id, expected := range map[ResourceID]string{MMDB: "Country.mmdb", ASN: "aSn.MmDb", GeoIP: "gEOiP.DAT", GeoSite: "gEoSiTe.DaT"} {
		path, err := Path(home, id)
		if err != nil || filepath.Base(path) != expected {
			t.Fatalf("Geo path %s=%s %v", id, path, err)
		}
	}
	if err := os.Remove(filepath.Join(home, "Country.mmdb")); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(home, "Country.mmdb"), 0700); err != nil {
		t.Fatal(err)
	}
	path, err := Path(home, MMDB)
	if err != nil || filepath.Base(path) != "geoip.db" {
		t.Fatalf("directory counted as database: %s %v", path, err)
	}
}
