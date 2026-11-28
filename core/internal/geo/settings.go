// Package geo 管理四类 Geo 数据库（mmdb/asn/geoip/geosite）的磁盘契约、串行可取消下载、
// 候选校验、热换提交与最新快照 WebSocket 推送，不接触核心互斥锁。
package geo

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"github.com/VOD-Studio/ArkClash/core/internal/backup"
	"github.com/metacubex/mihomo/component/geodata"
)

type ResourceID string

const (
	MMDB    ResourceID = "mmdb"
	ASN     ResourceID = "asn"
	GeoIP   ResourceID = "geoip"
	GeoSite ResourceID = "geosite"
)

var IDs = []ResourceID{MMDB, ASN, GeoIP, GeoSite}

const geoJSONLimit = 16 << 10

var errGeoJSONFile = errors.New("invalid Geo JSON file")

type URLs struct {
	MMDB    string `json:"mmdb"`
	ASN     string `json:"asn"`
	GeoIP   string `json:"geoip"`
	GeoSite string `json:"geosite"`
}

type Settings struct {
	Version       int    `json:"version"`
	Revision      string `json:"revision"`
	AutoUpdate    bool   `json:"autoUpdate"`
	IntervalHours int    `json:"intervalHours"`
	URLs          URLs   `json:"urls"`
}

type Metadata struct {
	Version       int   `json:"version"`
	Managed       bool  `json:"managed"`
	LastAttemptAt int64 `json:"lastAttemptAt"`
}

func DefaultSettings() Settings {
	const base = "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/"
	return Settings{Version: 1, Revision: "default", AutoUpdate: true, IntervalHours: 24, URLs: URLs{
		MMDB: base + "geoip.metadb", ASN: base + "GeoLite2-ASN.mmdb",
		GeoIP: base + "geoip.dat", GeoSite: base + "geosite.dat",
	}}
}

func geoIndex(id ResourceID) int {
	for i, candidate := range IDs {
		if id == candidate {
			return i
		}
	}
	return -1
}

func (s Settings) source(id ResourceID) string {
	switch id {
	case MMDB:
		return s.URLs.MMDB
	case ASN:
		return s.URLs.ASN
	case GeoIP:
		return s.URLs.GeoIP
	case GeoSite:
		return s.URLs.GeoSite
	}
	return ""
}

func ValidURL(source string) bool {
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

func ValidateSettings(settings Settings) error {
	if settings.Version != 1 || settings.Revision == "" || settings.IntervalHours < 1 || settings.IntervalHours > 8760 {
		return errors.New("geo_invalid_settings")
	}
	for _, id := range IDs {
		if !ValidURL(settings.source(id)) {
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

func ReadSettings(home string) (Settings, error) {
	data, err := readGeoJSONFile(backup.DataPath(home, "geo-settings.json"))
	if errors.Is(err, os.ErrNotExist) {
		return DefaultSettings(), nil
	}
	if errors.Is(err, errGeoJSONFile) {
		return Settings{}, errors.New("geo_invalid_settings")
	}
	if err != nil {
		return Settings{}, errors.New("geo_io")
	}
	var settings Settings
	if !geoRequiredFields(data, "version", "revision", "autoUpdate", "intervalHours", "urls") || decodeGeoJSON(data, &settings) != nil {
		return Settings{}, errors.New("geo_invalid_settings")
	}
	var object map[string]json.RawMessage
	_ = json.Unmarshal(data, &object)
	if !geoRequiredFields(object["urls"], "mmdb", "asn", "geoip", "geosite") {
		return Settings{}, errors.New("geo_invalid_settings")
	}
	if err := ValidateSettings(settings); err != nil {
		return Settings{}, err
	}
	return settings, nil
}

func geoMetadataPath(home string, id ResourceID) string {
	return filepath.Join(home, "geo-"+string(id)+".json")
}

func readGeoMetadata(home string, id ResourceID) (Metadata, error) {
	data, err := readGeoJSONFile(geoMetadataPath(home, id))
	if errors.Is(err, os.ErrNotExist) {
		return Metadata{Version: 1}, nil
	}
	if errors.Is(err, errGeoJSONFile) {
		return Metadata{}, errors.New("geo_metadata_invalid")
	}
	if err != nil {
		return Metadata{}, errors.New("geo_io")
	}
	var metadata Metadata
	if !geoRequiredFields(data, "version", "managed", "lastAttemptAt") || decodeGeoJSON(data, &metadata) != nil || metadata.Version != 1 || metadata.LastAttemptAt < 0 {
		return Metadata{}, errors.New("geo_metadata_invalid")
	}
	return metadata, nil
}

func writeGeoMetadata(home string, id ResourceID, metadata Metadata) error {
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

// Path 的 ReadDir 文件名顺序与 mihomo 相同，但列表读取不改变全局 GeoipName。
func Path(home string, id ResourceID) (string, error) {
	var names []string
	var fallback string
	switch id {
	case MMDB:
		names, fallback = []string{"Country.mmdb", "geoip.db", "geoip.metadb"}, "geoip.metadb"
	case ASN:
		names, fallback = []string{"ASN.mmdb"}, "ASN.mmdb"
	case GeoIP:
		names, fallback = []string{"GeoIP.dat"}, "GeoIP.dat"
	case GeoSite:
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

func SetURLs(settings Settings) {
	geodata.SetMmdbUrl(settings.URLs.MMDB)
	geodata.SetASNUrl(settings.URLs.ASN)
	geodata.SetGeoIpUrl(settings.URLs.GeoIP)
	geodata.SetGeoSiteUrl(settings.URLs.GeoSite)
}
