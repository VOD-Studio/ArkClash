package backup

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math/bits"
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

var rfc2617Shift = [64]uint{
	7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
	5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
	4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
	6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}

var rfc2617Table = [64]uint32{
	0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
	0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
	0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
	0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
	0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
	0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
	0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
	0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
}

// WebDAV HTTP Digest（RFC 2617）协议固定要求计算 H(A1)/H(A2) 挑战响应，并非密码存储哈希。
func digestMD5(s string) string {
	msg := []byte(s)
	bitLen := uint64(len(msg)) * 8
	msg = append(msg, 0x80)
	for len(msg)%64 != 56 {
		msg = append(msg, 0)
	}
	var lenBuf [8]byte
	binary.LittleEndian.PutUint64(lenBuf[:], bitLen)
	msg = append(msg, lenBuf[:]...)

	a0, b0, c0, d0 := uint32(0x67452301), uint32(0xefcdab89), uint32(0x98badcfe), uint32(0x10325476)
	var m [16]uint32
	for offset := 0; offset < len(msg); offset += 64 {
		for i := range 16 {
			m[i] = binary.LittleEndian.Uint32(msg[offset+i*4 : offset+i*4+4])
		}
		a, b, c, d := a0, b0, c0, d0
		for i := range 64 {
			var f uint32
			var g int
			switch {
			case i < 16:
				f = (b & c) | (^b & d)
				g = i
			case i < 32:
				f = (d & b) | (^d & c)
				g = (5*i + 1) % 16
			case i < 48:
				f = b ^ c ^ d
				g = (3*i + 5) % 16
			default:
				f = c ^ (b | ^d)
				g = (7 * i) % 16
			}
			f = f + a + rfc2617Table[i] + m[g]
			a = d
			d = c
			c = b
			b = b + bits.RotateLeft32(f, int(rfc2617Shift[i]))
		}
		a0 += a
		b0 += b
		c0 += c
		d0 += d
	}
	var out [16]byte
	binary.LittleEndian.PutUint32(out[0:4], a0)
	binary.LittleEndian.PutUint32(out[4:8], b0)
	binary.LittleEndian.PutUint32(out[8:12], c0)
	binary.LittleEndian.PutUint32(out[12:16], d0)
	return hex.EncodeToString(out[:])
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
