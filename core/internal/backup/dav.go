package backup

import (
	"context"
	"crypto/md5"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/metacubex/http"
)

type DAVSettings struct {
	Address  string `json:"address"`
	Username string `json:"username"`
	Password string `json:"password"`
	FileName string `json:"fileName"`
}

var ErrDAVSettings = errors.New("backup_dav_settings")
var ErrDAVResponse = errors.New("backup_dav_response")
var ErrDAVNetwork = errors.New("backup_dav_network")

func davURL(settings DAVSettings) (*url.URL, error) {
	if len(settings.Address) > 2048 || len(settings.Username) > 128 || len(settings.Password) > 4096 ||
		settings.Username == "" || settings.Password == "" || settings.FileName == "" || len(settings.FileName) > 255 ||
		strings.ContainsAny(settings.Username, ":\r\n") ||
		strings.ContainsAny(settings.FileName, "/\\:*?\"<>|\x00\r\n") ||
		settings.FileName == "." || settings.FileName == ".." {
		return nil, ErrDAVSettings
	}
	u, err := url.Parse(settings.Address)
	if err != nil || !validDAVURL(u) || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return nil, ErrDAVSettings
	}
	return u, nil
}

func validDAVURL(u *url.URL) bool {
	return u != nil && (u.Scheme == "http" || u.Scheme == "https") && u.Hostname() != ""
}

func DirectTransport() *http.Transport {
	return &http.Transport{
		DialContext:           (&net.Dialer{Timeout: 8 * time.Second}).DialContext,
		TLSHandshakeTimeout:   8 * time.Second,
		ResponseHeaderTimeout: 60 * time.Second,
		DisableKeepAlives:     true,
	}
}

func DAV(ctx context.Context, transport http.RoundTripper, settings DAVSettings, action, file string) error {
	base, err := davURL(settings)
	if err != nil {
		return err
	}
	client := &http.Client{
		Transport:     transport,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse },
		Timeout:       128 * time.Second,
	}
	folder := *base
	folder.Path = strings.TrimRight(base.Path, "/") + "/ArkClash"
	folder.RawPath = strings.TrimRight(base.EscapedPath(), "/") + "/ArkClash"
	target := folder
	target.Path += "/" + settings.FileName
	target.RawPath += "/" + url.PathEscape(settings.FileName)
	switch action {
	case "probe":
		response, err := davRequest(ctx, client, settings, "OPTIONS", base, "")
		return finishDAV(response, err, 200, 204)
	case "upload":
		response, err := davRequest(ctx, client, settings, "MKCOL", &folder, "")
		if err := finishDAV(response, err, 200, 201, 204, 405); err != nil {
			return err
		}
		response, err = davRequest(ctx, client, settings, http.MethodPut, &target, file)
		return finishDAV(response, err, 200, 201, 204)
	case "download":
		response, err := davRequest(ctx, client, settings, http.MethodGet, &target, "")
		if err != nil {
			return err
		}
		defer response.Body.Close()
		if response.StatusCode != 200 && response.StatusCode != 206 {
			return davStatus(response.StatusCode)
		}
		return saveDAV(response, file)
	default:
		return ErrDAVSettings
	}
}

func davStatus(code int) error {
	return fmt.Errorf("backup_dav_http_%d", code)
}

func finishDAV(response *http.Response, err error, accepted ...int) error {
	if err != nil {
		return err
	}
	defer response.Body.Close()
	for _, code := range accepted {
		if response.StatusCode == code {
			return nil
		}
	}
	return davStatus(response.StatusCode)
}

func saveDAV(response *http.Response, name string) (err error) {
	if response.ContentLength >= maxArchive {
		return ErrLimit
	}
	var expected int64 = -1
	if response.StatusCode == 206 {
		var end int64
		if _, err := fmt.Sscanf(response.Header.Get("Content-Range"), "bytes 0-%d/%d", &end, &expected); err != nil ||
			expected < 1 || end != expected-1 ||
			response.Header.Get("Content-Range") != fmt.Sprintf("bytes 0-%d/%d", end, expected) {
			return ErrDAVResponse
		}
	}
	out, err := os.OpenFile(name, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return ErrIO
	}
	defer func() {
		err = errors.Join(err, out.Close())
		if err != nil {
			_ = os.Remove(name)
		}
	}()
	n, err := io.Copy(out, io.LimitReader(response.Body, maxArchive))
	if n >= maxArchive {
		return ErrLimit
	}
	if err != nil || (expected >= 0 && n != expected) {
		return ErrDAVResponse
	}
	return out.Sync()
}

func startDAVRequest(ctx context.Context, client *http.Client, method string, target *url.URL,
	auth, source string) (*http.Response, error) {
	var body io.Reader
	var size int64
	if source != "" {
		f, err := os.Open(source)
		if err != nil {
			return nil, ErrIO
		}
		defer f.Close()
		info, err := f.Stat()
		if err != nil {
			return nil, ErrIO
		}
		size = info.Size()
		body = f
	}
	request, err := http.NewRequestWithContext(ctx, method, target.String(), body)
	if err != nil {
		return nil, ErrDAVSettings
	}
	if body != nil {
		request.ContentLength = size
		request.Header.Set("Content-Type", "application/octet-stream")
	}
	if auth != "" {
		request.Header.Set("Authorization", auth)
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, ErrDAVNetwork
	}
	return response, nil
}

func origin(u *url.URL) string {
	port := u.Port()
	if port == "" {
		port = "80"
		if u.Scheme == "https" {
			port = "443"
		}
	}
	return u.Scheme + "://" + net.JoinHostPort(strings.ToLower(u.Hostname()), port)
}

func davRequest(ctx context.Context, client *http.Client, settings DAVSettings, method string,
	target *url.URL, source string) (*http.Response, error) {
	basic := "Basic " + base64.StdEncoding.EncodeToString([]byte(settings.Username+":"+settings.Password))
	auth, allowAuth, retried := basic, true, false
	for range 5 {
		response, err := startDAVRequest(ctx, client, method, target, auth, source)
		if err != nil {
			return nil, err
		}
		switch response.StatusCode {
		case 401:
			if allowAuth && !retried {
				digest := digestHeader(response.Header.Values("WWW-Authenticate"), settings, method, target.RequestURI())
				if digest != "" {
					response.Body.Close()
					auth, retried = digest, true
					continue
				}
			}
			return response, nil
		case 301, 302, 303, 307, 308:
			next, err := response.Location()
			response.Body.Close()
			if err != nil || !validDAVURL(next) || next.User != nil {
				return nil, ErrDAVResponse
			}
			allowAuth = allowAuth && origin(target) == origin(next)
			auth, target = "", next
			if allowAuth {
				auth = basic
			}
		default:
			return response, nil
		}
	}
	return nil, ErrDAVResponse
}

var digestField = regexp.MustCompile(`(?i)([a-z][a-z0-9_-]*)\s*=\s*("(?:[^"\\]|\\.)*"|[^,\s]+)`)

func digestHeader(challenges []string, settings DAVSettings, method, uri string) string {
	for _, value := range challenges {
		if len(value) < 7 || !strings.EqualFold(value[:7], "Digest ") || len(value) > 16384 {
			continue
		}
		params := map[string]string{}
		for _, field := range digestField.FindAllStringSubmatch(value[7:], -1) {
			params[strings.ToLower(field[1])] = unquoteDigest(field[2])
		}
		if h := buildDigest(params, settings, method, uri); h != "" {
			return h
		}
	}
	return ""
}

func unquoteDigest(s string) string {
	if strings.HasPrefix(s, "\"") {
		s = strings.TrimSuffix(strings.TrimPrefix(s, "\""), "\"")
		return strings.NewReplacer(`\"`, `"`, `\\`, `\`).Replace(s)
	}
	return s
}

func digestMD5(s string) string {
	hash := md5.Sum([]byte(s))
	return hex.EncodeToString(hash[:])
}

func buildDigest(params map[string]string, settings DAVSettings, method, uri string) string {
	if params["realm"] == "" || params["nonce"] == "" ||
		(params["algorithm"] != "" && !strings.EqualFold(params["algorithm"], "MD5")) {
		return ""
	}
	auth := false
	for qop := range strings.SplitSeq(params["qop"], ",") {
		auth = auth || strings.TrimSpace(qop) == "auth"
	}
	if params["qop"] != "" && !auth {
		return ""
	}
	parts := []string{"username=" + strconv.Quote(settings.Username), "realm=" + strconv.Quote(params["realm"]),
		"nonce=" + strconv.Quote(params["nonce"]), "uri=" + strconv.Quote(uri), "algorithm=MD5"}
	data := digestMD5(settings.Username+":"+params["realm"]+":"+settings.Password) + ":" + params["nonce"] + ":"
	if auth {
		nonce := revision()
		data += "00000001:" + nonce + ":auth:"
		parts = append(parts, "qop=auth", "nc=00000001", "cnonce="+strconv.Quote(nonce))
	}
	if opaque := params["opaque"]; opaque != "" {
		parts = append(parts, "opaque="+strconv.Quote(opaque))
	}
	parts = append(parts, "response="+strconv.Quote(digestMD5(data+digestMD5(method+":"+uri))))
	return "Digest " + strings.Join(parts, ", ")
}

func WorkspaceArchive(home, id string) (string, error) {
	if !validID(id) || !strings.HasPrefix(id, "backup-") {
		return "", ErrIO
	}
	return filepath.Join(home, id, "archive.zip"), nil
}
