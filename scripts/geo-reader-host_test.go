package main

import (
	"bytes"
	"crypto/sha1"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/metacubex/mihomo/component/geodata"
	"github.com/metacubex/mihomo/component/mmdb"
	C "github.com/metacubex/mihomo/constant"
	"github.com/oschwald/maxminddb-golang"
	"github.com/sirupsen/logrus"
)

const countryFixture = "GeoIP2-Country-Test.mmdb"
const asnFixture = "GeoLite2-ASN-Test.mmdb"

func geoReaderBytes(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", "geo", name))
	if err != nil {
		t.Fatal(err)
	}
	expected := map[string]string{
		countryFixture: "9e0a58e6df30dd8d279c9ede70bcb1f19e1bf72f",
		asnFixture: "16f4b201d9069fd0999bf4988ef3e8977fc4ed8e",
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
	// 已有 reader 的所有权仍在包内；测试不关闭安装过的 reader。
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

func TestGeoReaderConcurrentInstallRetainsOldReaders(t *testing.T) {
	home := geoReaderHome(t)
	mmdb.InstallIPReader(geoReaderOpen(t, filepath.Join(home, "geoip.metadb")))
	mmdb.InstallASNReader(geoReaderOpen(t, filepath.Join(home, "ASN.mmdb")))
	oldIP, oldASN := mmdb.IPInstance(), mmdb.ASNInstance()
	countryIP := net.ParseIP("81.2.69.142")
	asnIP, expectedASN, expectedOrg := geoReaderASNQuery(t, oldASN.Reader)
	check := func(ip mmdb.IPReader, asn mmdb.ASNReader) {
		if got := ip.LookupCode(countryIP); len(got) != 1 || got[0] != "gb" {
			t.Errorf("country lookup after install = %v, want [gb]", got)
		}
		if number, org := asn.LookupASN(asnIP); number != expectedASN || org != expectedOrg {
			t.Errorf("ASN lookup after install = %q / %q, want %q / %q", number, org, expectedASN, expectedOrg)
		}
	}
	check(oldIP, oldASN)
	// 候选先全部打开，防止准备失败时遗留等待启动的查询 goroutine。
	candidatesIP := make([]*maxminddb.Reader, 32)
	candidatesASN := make([]*maxminddb.Reader, 32)
	for index := range candidatesIP {
		candidatesIP[index] = geoReaderOpen(t, filepath.Join(home, "geoip.metadb"))
		candidatesASN[index] = geoReaderOpen(t, filepath.Join(home, "ASN.mmdb"))
	}
	start := make(chan struct{})
	var readers sync.WaitGroup
	for range 8 {
		readers.Add(1)
		go func() {
			defer readers.Done()
			<-start
			for range 500 {
				check(oldIP, oldASN)
				check(mmdb.IPInstance(), mmdb.ASNInstance())
			}
		}()
	}
	retainedIP := []mmdb.IPReader{oldIP}
	retainedASN := []mmdb.ASNReader{oldASN}
	close(start)
	for index := range candidatesIP {
		mmdb.InstallIPReader(candidatesIP[index])
		mmdb.InstallASNReader(candidatesASN[index])
		ip, asn := mmdb.IPInstance(), mmdb.ASNInstance()
		if ip.Reader != candidatesIP[index] || asn.Reader != candidatesASN[index] {
			t.Error("Install did not publish the supplied candidate")
		}
		retainedIP = append(retainedIP, ip)
		retainedASN = append(retainedASN, asn)
	}
	readers.Wait()
	for index := range retainedIP {
		check(retainedIP[index], retainedASN[index])
	}
}

func TestGeoReaderReloadAndLoadFromBytes(t *testing.T) {
	home := geoReaderHome(t)
	mmdb.ReloadIP()
	mmdb.LoadFromBytes(geoReaderBytes(t, countryFixture))
	fromBytes := mmdb.IPInstance()
	if got := fromBytes.LookupCode(net.ParseIP("81.2.69.142")); len(got) != 1 || got[0] != "gb" {
		t.Fatalf("LoadFromBytes country = %v", got)
	}
	// 初始化后再次 LoadFromBytes 必须忽略输入，而非解析无效数据或覆盖 reader。
	mmdb.LoadFromBytes([]byte("not an mmdb"))
	if mmdb.IPInstance().Reader != fromBytes.Reader {
		t.Fatal("LoadFromBytes replaced an initialized reader")
	}
	mmdb.ReloadIP()
	fileIP := mmdb.IPInstance()
	if fileIP.Reader == fromBytes.Reader {
		t.Fatal("ReloadIP did not reset lazy initialization")
	}
	mmdb.LoadFromBytes([]byte("also ignored after lazy file initialization"))
	if mmdb.IPInstance().Reader != fileIP.Reader {
		t.Fatal("LoadFromBytes replaced a file-backed reader")
	}
	oldASN := mmdb.ASNInstance()
	asnIP, expectedASN, expectedOrg := geoReaderASNQuery(t, oldASN.Reader)
	mmdb.ReloadASN()
	newASN := mmdb.ASNInstance()
	if newASN.Reader == oldASN.Reader {
		t.Fatal("ReloadASN did not reset lazy initialization")
	}
	for _, reader := range []mmdb.IPReader{fromBytes, fileIP} {
		if got := reader.LookupCode(net.ParseIP("81.2.69.142")); len(got) != 1 || got[0] != "gb" {
			t.Errorf("retired reader after ReloadIP = %v", got)
		}
	}
	for _, reader := range []mmdb.ASNReader{oldASN, newASN} {
		if number, org := reader.LookupASN(asnIP); number != expectedASN || org != expectedOrg {
			t.Error("retired ASN reader became unreadable after ReloadASN")
		}
	}
	if !mmdb.Verify(filepath.Join(home, "geoip.metadb")) || mmdb.Verify(filepath.Join(home, "missing.mmdb")) {
		t.Error("Verify did not distinguish valid and missing databases")
	}
}

type geoReaderLogBuffer struct {
	mu sync.Mutex
	data bytes.Buffer
}

func (buffer *geoReaderLogBuffer) Write(value []byte) (int, error) {
	buffer.mu.Lock()
	defer buffer.mu.Unlock()
	return buffer.data.Write(value)
}

func (buffer *geoReaderLogBuffer) String() string {
	buffer.mu.Lock()
	defer buffer.mu.Unlock()
	return buffer.data.String()
}

func TestGeoInitializationDownloadFailureRedactsURL(t *testing.T) {
	oldHome, oldIPName, oldSiteName, oldASNName := C.Path.HomeDir(), C.GeoipName, C.GeositeName, C.ASNName
	oldMode := geodata.GeodataMode()
	oldMMDB, oldASN, oldIP, oldSite := geodata.MmdbUrl(), geodata.ASNUrl(), geodata.GeoIpUrl(), geodata.GeoSiteUrl()
	logger := logrus.StandardLogger()
	oldOutput := logger.Out
	var captured geoReaderLogBuffer
	logrus.SetOutput(&captured)
	t.Cleanup(func() {
		logrus.SetOutput(oldOutput)
		C.SetHomeDir(oldHome)
		C.GeoipName, C.GeositeName, C.ASNName = oldIPName, oldSiteName, oldASNName
		geodata.SetGeodataMode(oldMode)
		geodata.SetMmdbUrl(oldMMDB)
		geodata.SetASNUrl(oldASN)
		geodata.SetGeoIpUrl(oldIP)
		geodata.SetGeoSiteUrl(oldSite)
	})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		connection, _, err := w.(http.Hijacker).Hijack()
		if err == nil {
			connection.Close()
		}
	}))
	defer server.Close()
	const token = "fixture-private-query-credential"
	source := server.URL + "/resource?token=" + token
	geodata.SetMmdbUrl(source)
	geodata.SetASNUrl(source)
	geodata.SetGeoIpUrl(source)
	geodata.SetGeoSiteUrl(source)
	for _, item := range []struct {
		name string
		mode bool
		initialize func() error
	}{
		{"mmdb", false, geodata.InitGeoIP},
		{"asn", false, geodata.InitASN},
		{"geoip", true, geodata.InitGeoIP},
		{"geosite", true, geodata.InitGeoSite},
	} {
		t.Run(item.name, func(t *testing.T) {
			C.SetHomeDir(t.TempDir())
			geodata.SetGeodataMode(item.mode)
			err := item.initialize()
			if err == nil {
				t.Fatal("initialization accepted a failed download")
			}
			if strings.Contains(err.Error(), token) || strings.Contains(err.Error(), server.URL) {
				t.Error("initialization error disclosed the source URL or credential")
			}
			if !strings.Contains(err.Error(), "geo_download_failed") {
				t.Error("initialization failure omitted the stable redacted error code")
			}
		})
	}
	if output := captured.String(); strings.Contains(output, token) || strings.Contains(output, server.URL) {
		t.Error("initialization logs disclosed the source URL or credential")
	}
}
