package main

import (
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
)

type dnsOverrideSettings struct {
	Revision string             `json:"revision"`
	Entries  dnsOverrideEntries `json:"entries"`
}

type dnsOverrideEntries struct {
	Listen         *string              `json:"listen,omitempty"`
	IPv6           *bool                `json:"ipv6,omitempty"`
	PreferH3       *bool                `json:"prefer-h3,omitempty"`
	EnhancedMode   *constant.DNSMode    `json:"enhanced-mode,omitempty"`
	FakeIPFilter   *[]string            `json:"fake-ip-filter,omitempty"`
	FakeIPMode     *constant.FilterMode `json:"fake-ip-filter-mode,omitempty"`
	DefaultServers *[]string            `json:"default-nameserver,omitempty"`
	Servers        *[]string            `json:"nameserver,omitempty"`
	Fallback       *[]string            `json:"fallback,omitempty"`
	ProxyServers   *[]string            `json:"proxy-server-nameserver,omitempty"`
	DirectServers  *[]string            `json:"direct-nameserver,omitempty"`
}

func replaceDNSField[T any](field *T, override *T) {
	if override != nil {
		*field = *override
	}
}

func (e dnsOverrideEntries) apply(raw *config.RawDNS) {
	replaceDNSField(&raw.Listen, e.Listen)
	replaceDNSField(&raw.IPv6, e.IPv6)
	replaceDNSField(&raw.PreferH3, e.PreferH3)
	replaceDNSField(&raw.EnhancedMode, e.EnhancedMode)
	replaceDNSField(&raw.FakeIPFilter, e.FakeIPFilter)
	replaceDNSField(&raw.FakeIPFilterMode, e.FakeIPMode)
	replaceDNSField(&raw.DefaultNameserver, e.DefaultServers)
	replaceDNSField(&raw.NameServer, e.Servers)
	replaceDNSField(&raw.Fallback, e.Fallback)
	replaceDNSField(&raw.ProxyServerNameserver, e.ProxyServers)
	replaceDNSField(&raw.DirectNameServer, e.DirectServers)
}

var (
	errDNSInvalid  = errors.New("dns_override_invalid")
	errDNSConflict = errors.New("dns_override_conflict")
	errDNSIO       = errors.New("dns_override_io")
	errDNSApply    = errors.New("dns_override_apply_failed")
	errDNSListen   = errors.New("dns_override_listen_failed")
)

func (s dnsOverrideSettings) validate() error {
	e := s.Entries
	if len(s.Revision) == 0 || len(s.Revision) > 80 ||
		(e.EnhancedMode != nil && *e.EnhancedMode == constant.DNSHosts) ||
		(e.DefaultServers != nil && len(*e.DefaultServers) == 0) || (e.Servers != nil && len(*e.Servers) == 0) {
		return errDNSInvalid
	}
	if e.Listen != nil && *e.Listen != "" {
		_, port, err := net.SplitHostPort(*e.Listen)
		value, parseErr := strconv.ParseUint(port, 10, 16)
		if err != nil || parseErr != nil || value == 0 || len(*e.Listen) > 320 {
			return errDNSInvalid
		}
	}
	for _, list := range []*[]string{e.FakeIPFilter, e.DefaultServers, e.Servers, e.Fallback, e.ProxyServers, e.DirectServers} {
		if list == nil {
			continue
		}
		if len(*list) > 256 {
			return errDNSInvalid
		}
		for _, item := range *list {
			if item == "" || len(item) > 2048 || strings.TrimSpace(item) != item || strings.ContainsAny(item, "\x00\r\n") {
				return errDNSInvalid
			}
		}
		if list != e.FakeIPFilter {
			if _, err := dns.ParseNameServer(*list); err != nil {
				return errDNSInvalid
			}
		}
	}
	return nil
}

func dnsOverridesPath(home string) string {
	return filepath.Join(home, "dns-overrides.json")
}

func readDNSOverrides(home string) (dnsOverrideSettings, error) {
	file, err := os.Open(dnsOverridesPath(home))
	if errors.Is(err, os.ErrNotExist) {
		return dnsOverrideSettings{Revision: "default"}, nil
	}
	if err != nil {
		return dnsOverrideSettings{}, errDNSIO
	}
	defer file.Close()
	var settings dnsOverrideSettings
	if err := decodeProfileSettings(file, &settings); err != nil {
		return settings, errDNSInvalid
	}
	return settings, settings.validate()
}

type dnsOverrideRequest = profileSettingsRequest[dnsOverrideSettings]

func postDNSOverrides(w http.ResponseWriter, r *http.Request) {
	var request dnsOverrideRequest
	if err := decodeProfileSettings(r.Body, &request); err != nil {
		writeError(w, r, http.StatusBadRequest, errDNSInvalid)
		return
	}
	if err := updateDNSOverrides(request); err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, errDNSConflict) {
			status = http.StatusConflict
		}
		writeError(w, r, status, err)
		return
	}
	render.NoContent(w, r)
}

func updateDNSOverrides(request dnsOverrideRequest) error {
	mu.Lock()
	var wait func()
	defer func() {
		mu.Unlock()
		if wait != nil {
			wait()
		}
	}()
	if !profileSettingsCurrent(request.BootID, request.ExpectedRevision, current.DNS.Revision, request.Settings.Revision) {
		return errDNSConflict
	}
	if err := request.Settings.validate(); err != nil {
		return err
	}
	next := current
	next.DNS = request.Settings
	var err error
	wait, err = applyProfileSettingsLocked(next, dnsOverridesPath(next.HomeDir), next.DNS)
	switch err {
	case nil:
		return nil
	case errProfileSettingsInvalid:
		return errDNSInvalid
	case errProfileSettingsIO:
		return errDNSIO
	case errProfileSettingsListen:
		return errDNSListen
	default:
		return errDNSApply
	}
}

func dnsListenerAvailable(address string, mark int) bool {
	if address == "" || address == desiredInbound.dnsListen {
		return true
	}
	lc := inbound.NewListenConfig()
	lc.SetRouteMark(mark)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	tcp, err := lc.Listen(ctx, "tcp", address)
	if err != nil {
		return false
	}
	defer tcp.Close()
	udp, err := lc.ListenPacket(ctx, "udp", address)
	if err != nil {
		return false
	}
	return udp.Close() == nil
}
