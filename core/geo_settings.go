package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"github.com/metacubex/mihomo/component/geodata"
)

type geoResourceID string

const (
	geoMMDB geoResourceID = "mmdb"
	geoASN  geoResourceID = "asn"
	geoIP   geoResourceID = "geoip"
	geoSite geoResourceID = "geosite"
)

var geoIDs = []geoResourceID{geoMMDB, geoASN, geoIP, geoSite}

const geoJSONLimit = 16 << 10

var errGeoJSONFile = errors.New("invalid Geo JSON file")

type geoURLs struct {
	MMDB    string `json:"mmdb"`
	ASN     string `json:"asn"`
	GeoIP   string `json:"geoip"`
	GeoSite string `json:"geosite"`
}

type geoSettings struct {
	Version       int     `json:"version"`
	Revision      string  `json:"revision"`
	AutoUpdate    bool    `json:"autoUpdate"`
	IntervalHours int     `json:"intervalHours"`
	URLs          geoURLs `json:"urls"`
}

type geoMetadata struct {
	Version       int   `json:"version"`
	Managed       bool  `json:"managed"`
	LastAttemptAt int64 `json:"lastAttemptAt"`
}

func defaultGeoSettings() geoSettings {
	const base = "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/"
	return geoSettings{Version: 1, Revision: "default", AutoUpdate: true, IntervalHours: 24, URLs: geoURLs{
		MMDB: base + "geoip.metadb", ASN: base + "GeoLite2-ASN.mmdb",
		GeoIP: base + "geoip.dat", GeoSite: base + "geosite.dat",
	}}
}

func geoIndex(id geoResourceID) int {
	for i, candidate := range geoIDs {
		if id == candidate {
			return i
		}
	}
	return -1
}

func (s geoSettings) source(id geoResourceID) string {
	switch id {
	case geoMMDB:
		return s.URLs.MMDB
	case geoASN:
		return s.URLs.ASN
	case geoIP:
		return s.URLs.GeoIP
	case geoSite:
		return s.URLs.GeoSite
	}
	return ""
}

func validGeoURL(source string) bool {
	if len(source) == 0 || len(source) > 2048 {
		return false
	}
	for _, character := range source {
		if character <= ' ' || character == 127 || character == '\\' {
			return false
		}
	}
	target, err := url.Parse(source)
	return err == nil && (target.Scheme == "http" || target.Scheme == "https") && target.Hostname() != "" && target.User == nil
}

func validateGeoSettings(settings geoSettings) error {
	if settings.Version != 1 || settings.Revision == "" || settings.IntervalHours < 1 || settings.IntervalHours > 8760 {
		return errors.New("geo_invalid_settings")
	}
	for _, id := range geoIDs {
		if !validGeoURL(settings.source(id)) {
			return errors.New("geo_invalid_url")
		}
	}
	return nil
}

// 所有磁盘和请求 JSON 都拒绝未知字段、空值及尾随内容。
func decodeGeoJSON(data []byte, value any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(value); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return errors.New("invalid JSON")
	}
	return nil
}

func geoRequiredFields(data []byte, fields ...string) bool {
	var values map[string]json.RawMessage
	if json.Unmarshal(data, &values) != nil || len(values) != len(fields) {
		return false
	}
	for _, field := range fields {
		value, ok := values[field]
		if !ok || bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return false
		}
	}
	return true
}

func readGeoJSONFile(path string) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, errGeoJSONFile
	}
	data, err := io.ReadAll(io.LimitReader(file, geoJSONLimit+1))
	if err != nil {
		return nil, err
	}
	if len(data) > geoJSONLimit {
		return nil, errGeoJSONFile
	}
	return data, nil
}

func readGeoSettings(home string) (geoSettings, error) {
	data, err := readGeoJSONFile(filepath.Join(home, "geo-settings.json"))
	if errors.Is(err, os.ErrNotExist) {
		return defaultGeoSettings(), nil
	}
	if errors.Is(err, errGeoJSONFile) {
		return geoSettings{}, errors.New("geo_invalid_settings")
	}
	if err != nil {
		return geoSettings{}, errors.New("geo_io")
	}
	var settings geoSettings
	if !geoRequiredFields(data, "version", "revision", "autoUpdate", "intervalHours", "urls") || decodeGeoJSON(data, &settings) != nil {
		return geoSettings{}, errors.New("geo_invalid_settings")
	}
	var object map[string]json.RawMessage
	_ = json.Unmarshal(data, &object)
	if !geoRequiredFields(object["urls"], "mmdb", "asn", "geoip", "geosite") {
		return geoSettings{}, errors.New("geo_invalid_settings")
	}
	if err := validateGeoSettings(settings); err != nil {
		return geoSettings{}, err
	}
	return settings, nil
}

func geoMetadataPath(home string, id geoResourceID) string {
	return filepath.Join(home, "geo-"+string(id)+".json")
}

func readGeoMetadata(home string, id geoResourceID) (geoMetadata, error) {
	data, err := readGeoJSONFile(geoMetadataPath(home, id))
	if errors.Is(err, os.ErrNotExist) {
		return geoMetadata{Version: 1}, nil
	}
	if errors.Is(err, errGeoJSONFile) {
		return geoMetadata{}, errors.New("geo_metadata_invalid")
	}
	if err != nil {
		return geoMetadata{}, errors.New("geo_io")
	}
	var metadata geoMetadata
	if !geoRequiredFields(data, "version", "managed", "lastAttemptAt") || decodeGeoJSON(data, &metadata) != nil || metadata.Version != 1 || metadata.LastAttemptAt < 0 {
		return geoMetadata{}, errors.New("geo_metadata_invalid")
	}
	return metadata, nil
}

func writeGeoMetadata(home string, id geoResourceID, metadata geoMetadata) error {
	data, err := json.Marshal(metadata)
	if err != nil {
		return errors.New("geo_io")
	}
	file, err := os.CreateTemp(home, "arkclash-geo-"+string(id)+"-metadata-*.tmp")
	if err != nil {
		return errors.New("geo_io")
	}
	name := file.Name()
	defer os.Remove(name)
	_, err = file.Write(data)
	if err == nil {
		err = file.Sync()
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Rename(name, geoMetadataPath(home, id))
	}
	if err == nil {
		directory, openErr := os.Open(home)
		if openErr != nil {
			err = openErr
		} else {
			err = directory.Sync()
			if closeErr := directory.Close(); err == nil {
				err = closeErr
			}
		}
	}
	if err != nil {
		return errors.New("geo_io")
	}
	return nil
}

// ReadDir 的文件名顺序与 mihomo 相同，但列表读取不改变全局 GeoipName。
func geoPath(home string, id geoResourceID) (string, error) {
	var names []string
	var fallback string
	switch id {
	case geoMMDB:
		names, fallback = []string{"Country.mmdb", "geoip.db", "geoip.metadb"}, "geoip.metadb"
	case geoASN:
		names, fallback = []string{"ASN.mmdb"}, "ASN.mmdb"
	case geoIP:
		names, fallback = []string{"GeoIP.dat"}, "GeoIP.dat"
	case geoSite:
		names, fallback = []string{"GeoSite.dat"}, "geosite.dat"
	default:
		return "", errors.New("geo_invalid_settings")
	}
	entries, err := os.ReadDir(home)
	if err != nil {
		return filepath.Join(home, fallback), errors.New("geo_io")
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		for _, name := range names {
			if strings.EqualFold(entry.Name(), name) {
				if entry.Type().IsRegular() {
					return filepath.Join(home, entry.Name()), nil
				}
				info, err := os.Stat(filepath.Join(home, entry.Name()))
				if err != nil {
					return filepath.Join(home, entry.Name()), errors.New("geo_io")
				}
				if info.Mode().IsRegular() {
					return filepath.Join(home, entry.Name()), nil
				}
			}
		}
	}
	return filepath.Join(home, fallback), nil
}

func setGeoURLs(settings geoSettings) {
	geodata.SetMmdbUrl(settings.URLs.MMDB)
	geodata.SetASNUrl(settings.URLs.ASN)
	geodata.SetGeoIpUrl(settings.URLs.GeoIP)
	geodata.SetGeoSiteUrl(settings.URLs.GeoSite)
}
