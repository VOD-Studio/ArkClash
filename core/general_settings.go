package main

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"os"
	"reflect"
	"strconv"
	"strings"
	"unicode"

	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/component/auth"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/component/trie"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/listener"
	authStore "github.com/metacubex/mihomo/listener/auth"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
)

type generalPorts struct {
	Mixed  int `json:"mixed"`
	HTTP   int `json:"http"`
	SOCKS  int `json:"socks"`
	Redir  int `json:"redir"`
	TProxy int `json:"tproxy"`
}

type generalAuthentication struct {
	Enabled  bool   `json:"enabled"`
	Username string `json:"username"`
	Password string `json:"password"`
}

type generalSettings struct {
	Revision         string                 `json:"revision"`
	Ports            *generalPorts          `json:"ports,omitempty"`
	Authentication   *generalAuthentication `json:"authentication,omitempty"`
	ControllerSecret string                 `json:"controllerSecret"`
	UserAgent        string                 `json:"userAgent"`
	Hosts            map[string][]string    `json:"hosts"`
	DelayTimeout     int                    `json:"delayTimeout"`
	CloseConnections *bool                  `json:"closeConnections,omitempty"`
	LogLevel         string                 `json:"logLevel"`
	CaptureLogs      bool                   `json:"captureLogs"`
}

const panelPort = 9090

var errGeneralInvalid = errors.New("general_settings_invalid")
var errGeneralConflict = errors.New("general_settings_conflict")
var errGeneralIO = errors.New("general_settings_io")
var errGeneralApply = errors.New("general_settings_apply_failed")
var errGeneralPort = errors.New("general_settings_port_busy")
var errGeneralPanel = errors.New("general_settings_controller_busy")

func (p generalPorts) values() [5]int {
	return [5]int{p.Mixed, p.HTTP, p.SOCKS, p.Redir, p.TProxy}
}

func (s generalSettings) level() log.LogLevel {
	if level, ok := log.LogLevelMapping[s.LogLevel]; ok {
		return level
	}
	return log.ERROR
}

func validGeneralText(value string, limit int) bool {
	return len(value) <= limit && strings.TrimSpace(value) == value &&
		strings.IndexFunc(value, unicode.IsControl) == -1
}

func (s generalSettings) validate() error {
	if !validGeneralText(s.Revision, 96) || s.Revision == "" || !validGeneralText(s.UserAgent, 512) {
		return errGeneralInvalid
	}
	switch s.DelayTimeout {
	case 500, 1000, 2000, 5000, 8000:
	default:
		return errGeneralInvalid
	}
	if _, ok := log.LogLevelMapping[s.LogLevel]; !ok {
		return errGeneralInvalid
	}
	if s.ControllerSecret != "" && (!validGeneralText(s.ControllerSecret, 512) ||
		strings.ContainsAny(s.ControllerSecret, " \t")) {
		return errGeneralInvalid
	}
	if s.Ports != nil {
		seen := map[int]bool{19090: true}
		if s.ControllerSecret != "" {
			seen[panelPort] = true
		}
		if s.Ports.Mixed == 0 {
			return errGeneralInvalid
		}
		for _, port := range s.Ports.values() {
			if port == 0 {
				continue
			}
			if port < 1024 || port > 49151 || seen[port] {
				return errGeneralInvalid
			}
			seen[port] = true
		}
	}
	if a := s.Authentication; a != nil {
		if !validGeneralText(a.Username, 128) || !validGeneralText(a.Password, 512) ||
			strings.Contains(a.Username, ":") || (a.Enabled && (a.Username == "" || a.Password == "")) {
			return errGeneralInvalid
		}
	}
	return validateGeneralHosts(s.Hosts)
}

func validateGeneralHosts(hosts map[string][]string) error {
	if len(hosts) > 256 {
		return errGeneralInvalid
	}
	keys := trie.New[struct{}]()
	domains := make(map[string]bool)
	aliases := make(map[string]string)
	for domain, values := range hosts {
		key := strings.ToLower(domain)
		if !validHostName(domain) || domains[key] || keys.Insert(domain, struct{}{}) != nil ||
			len(values) == 0 || len(values) > 32 {
			return errGeneralInvalid
		}
		domains[key] = true
		for _, value := range values {
			if addr, err := netip.ParseAddr(value); err == nil {
				if addr.Zone() != "" {
					return errGeneralInvalid
				}
			} else if !validHostName(value) {
				return errGeneralInvalid
			}
		}
		resolved, err := resolver.NewHostValue(values)
		if err != nil {
			return errGeneralInvalid
		}
		if resolved.IsDomain {
			aliases[key] = strings.ToLower(resolved.Domain)
		}
	}
	for domain := range aliases {
		seen := make(map[string]bool)
		for next := domain; next != ""; next = aliases[next] {
			if seen[next] {
				return errGeneralInvalid
			}
			seen[next] = true
		}
	}
	return nil
}

func validHostName(value string) bool {
	return value != "" && validGeneralText(value, 512) && !strings.ContainsAny(value, " /:?#@\t")
}

func generalSettingsPath(home string) string { return portableDataPath(home, "general-settings.json") }

func readGeneralSettings(home string) (generalSettings, error) {
	file, err := os.Open(generalSettingsPath(home))
	if errors.Is(err, os.ErrNotExist) {
		return generalSettings{Revision: "default", DelayTimeout: 8000, LogLevel: "error"}, nil
	}
	if err != nil {
		return generalSettings{}, errGeneralIO
	}
	defer file.Close()
	var settings generalSettings
	if err := decodeProfileSettings(file, &settings); err != nil {
		return settings, errGeneralInvalid
	}
	return settings, settings.validate()
}

func (s generalSettings) apply(raw *config.RawConfig) {
	raw.LogLevel = s.level()
	if s.UserAgent != "" {
		raw.GlobalUA = s.UserAgent
	}
	if p := s.Ports; p != nil {
		raw.MixedPort, raw.Port, raw.SocksPort, raw.RedirPort, raw.TProxyPort = p.Mixed, p.HTTP, p.SOCKS, p.Redir, p.TProxy
	}
	if a := s.Authentication; a != nil {
		raw.Authentication = nil
		raw.SkipAuthPrefixes = nil
		if a.Enabled {
			raw.Authentication = []string{a.Username + ":" + a.Password}
		}
	}
	if len(s.Hosts) != 0 && raw.Hosts == nil {
		raw.Hosts = make(map[string]any, len(s.Hosts))
	}
	for domain, values := range s.Hosts {
		for original := range raw.Hosts {
			if original != domain && strings.EqualFold(original, domain) {
				delete(raw.Hosts, original)
			}
		}
		raw.Hosts[domain] = values
	}
}

func postGeneralSettings(w http.ResponseWriter, r *http.Request) {
	var request profileSettingsRequest[generalSettings]
	if decodeProfileSettings(r.Body, &request) != nil {
		writeError(w, r, http.StatusBadRequest, errGeneralInvalid)
		return
	}
	if err := updateGeneralSettings(request); err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, errGeneralConflict) || errors.Is(err, errGeneralPort) || errors.Is(err, errGeneralPanel) {
			status = http.StatusConflict
		}
		writeError(w, r, status, err)
		return
	}
	render.NoContent(w, r)
}

func updateGeneralSettings(request profileSettingsRequest[generalSettings]) error {
	mu.Lock()
	var wait func()
	defer func() {
		mu.Unlock()
		if wait != nil {
			wait()
		}
	}()
	old := current
	s := request.Settings
	if !profileSettingsCurrent(request.BootID, request.ExpectedRevision, old.General.Revision, s.Revision) {
		return errGeneralConflict
	}
	if err := s.validate(); err != nil {
		return err
	}
	next := old
	next.General = s
	rebuild := !reflect.DeepEqual(old.General.Hosts, s.Hosts) ||
		s.Ports == nil && old.General.Ports != nil ||
		s.Authentication == nil && old.General.Authentication != nil
	previousInbound := desiredInbound
	targetInbound := previousInbound
	var cfg *config.Config
	if rebuild {
		var err error
		cfg, err = parseProfileSettingsConfig(&next, &targetInbound)
		if err != nil {
			return errGeneralApply
		}
	} else if s.Ports != nil {
		p := s.Ports
		b := &targetInbound.inbound
		b.MixedPort, b.Port, b.SocksPort, b.RedirPort, b.TProxyPort = p.Mixed, p.HTTP, p.SOCKS, p.Redir, p.TProxy
	}
	if err := preflightGeneralPorts(targetInbound, s.ControllerSecret != ""); err != nil {
		return err
	}
	path := generalSettingsPath(old.HomeDir)
	staged, err := stageProfileSettings(path, s)
	if err != nil {
		return errGeneralIO
	}
	defer os.Remove(staged)
	if err := setPanelControllerLocked(s.ControllerSecret); err != nil {
		publishRuntime()
		return errGeneralPanel
	}

	oldAuth := authStore.Default.Authenticator()
	if rebuild {
		wait, err = reloadPreparedLocked(next, cfg, targetInbound, true)
	} else {
		err = applyGeneralListenersLocked(targetInbound, s.Authentication)
	}
	if err == nil {
		if os.Rename(staged, path) == nil {
			current = next
			log.SetLevel(s.level())
			if !s.CaptureLogs && diagnosticLogs != nil {
				wait = together(wait, stopDiagnosticLogsLocked())
			}
			publishRuntime()
			return nil
		}
		err = errGeneralIO
	} else {
		err = errGeneralPort
	}

	if rebuild && wait != nil {
		previousConfig, parseErr := parseProfileSettingsConfig(&old, &previousInbound)
		if parseErr == nil {
			var rollback func()
			rollback, parseErr = reloadPreparedLocked(old, previousConfig, previousInbound, false)
			wait = together(wait, rollback)
		}
		if parseErr != nil {
			cleanupFailure = errors.Join(cleanupFailure, closeBusinessInbounds(), stopTun(), parseErr)
		}
	} else if !rebuild {
		authStore.Default.SetAuthenticator(oldAuth)
		inbound.SetSkipAuthPrefixes(previousInbound.inbound.SkipAuthPrefixes)
		if rollbackErr := applyGeneralListenersLocked(previousInbound, nil); rollbackErr != nil {
			cleanupFailure = errors.Join(cleanupFailure, closeBusinessInbounds(), stopTun(), rollbackErr)
		}
	}
	if setPanelControllerLocked(old.General.ControllerSecret) != nil {
		err = errGeneralApply
	}
	current = old
	log.SetLevel(old.General.level())
	publishRuntime()
	return err
}

func together(first, second func()) func() {
	return func() {
		if first != nil {
			first()
		}
		if second != nil {
			second()
		}
	}
}

func portsFromInbound(b config.Inbound) generalPorts {
	return generalPorts{b.MixedPort, b.Port, b.SocksPort, b.RedirPort, b.TProxyPort}
}

func preflightGeneralPorts(target inboundSettings, panel bool) error {
	b := target.inbound
	ports := portsFromInbound(b).values()
	address := "127.0.0.1"
	if b.AllowLan && b.BindAddress == "*" {
		address = ""
	} else if b.AllowLan {
		address = strings.Trim(b.BindAddress, "[]")
	}
	active := listener.GetPorts()
	for i, port := range ports {
		if port == 0 {
			continue
		}
		if port == 19090 || panel && port == panelPort {
			return errGeneralPort
		}
		if tunListener == nil || port == active.Port || port == active.SocksPort || port == active.RedirPort ||
			port == active.TProxyPort || port == active.MixedPort {
			continue
		}
		addr := net.JoinHostPort(address, strconv.Itoa(port))
		var lc net.ListenConfig
		socket, err := lc.Listen(context.Background(), "tcp", addr)
		if err != nil {
			return errGeneralPort
		}
		_ = socket.Close()
		if i == 0 || i == 2 || i == 4 {
			packet, err := lc.ListenPacket(context.Background(), "udp", addr)
			if err != nil {
				return errGeneralPort
			}
			_ = packet.Close()
		}
	}
	return nil
}

func applyGeneralListenersLocked(target inboundSettings, a *generalAuthentication) error {
	if a != nil {
		var users []auth.AuthUser
		if a.Enabled {
			users = []auth.AuthUser{{User: a.Username, Pass: a.Password}}
		}
		authStore.Default.SetAuthenticator(auth.NewAuthenticator(users))
		target.inbound.SkipAuthPrefixes = nil
		inbound.SetSkipAuthPrefixes(nil)
	}
	desiredInbound = target
	if tunListener == nil {
		return nil
	}
	old := listener.GetPorts()
	prior := generalPorts{old.MixedPort, old.Port, old.SocksPort, old.RedirPort, old.TProxyPort}.values()
	next := portsFromInbound(target.inbound).values()
	rebind := [...]func(int, C.Tunnel){
		listener.ReCreateMixed, listener.ReCreateHTTP, listener.ReCreateSocks, listener.ReCreateRedir, listener.ReCreateTProxy,
	}
	for i, bind := range rebind {
		if prior[i] != next[i] && prior[i] != 0 {
			bind(0, tunnel.Tunnel)
		}
	}
	for i, bind := range rebind {
		if prior[i] != next[i] && next[i] != 0 {
			bind(next[i], tunnel.Tunnel)
		}
	}
	active := listener.GetPorts()
	if (generalPorts{active.MixedPort, active.Port, active.SocksPort, active.RedirPort, active.TProxyPort}) != portsFromInbound(target.inbound) {
		return errGeneralPort
	}
	return nil
}
