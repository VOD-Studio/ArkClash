package main

import (
	"context"
	"errors"
	"time"

	corecfg "github.com/VOD-Studio/ArkClash/core/internal/config"
	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/adapter/inbound"
)

func postDNSOverrides(w http.ResponseWriter, r *http.Request) {
	var request corecfg.DNSOverrideRequest
	if err := corecfg.DecodeSettings(r.Body, &request); err != nil {
		writeError(w, r, http.StatusBadRequest, corecfg.ErrDNSInvalid)
		return
	}
	if err := updateDNSOverrides(request); err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, corecfg.ErrDNSConflict) {
			status = http.StatusConflict
		}
		writeError(w, r, status, err)
		return
	}
	render.NoContent(w, r)
}

func updateDNSOverrides(request corecfg.DNSOverrideRequest) error {
	return eng.withState(func(tx *stateTx) error {
		if !profileSettingsCurrent(request.BootID, request.ExpectedRevision, eng.current.DNS.Revision, request.Settings.Revision) {
			return corecfg.ErrDNSConflict
		}
		if err := request.Settings.Validate(); err != nil {
			return err
		}
		next := eng.current
		next.DNS = request.Settings
		err := tx.CommitSettingsFile(next, corecfg.DNSOverridesPath(next.HomeDir), next.DNS)
		switch err {
		case nil:
			return nil
		case corecfg.ErrSettingsInvalid:
			return corecfg.ErrDNSInvalid
		case corecfg.ErrSettingsIO:
			return corecfg.ErrDNSIO
		case corecfg.ErrSettingsListen:
			return corecfg.ErrDNSListen
		case corecfg.ErrDNSProxyServersRequired:
			return corecfg.ErrDNSProxyServersRequired
		default:
			return corecfg.ErrDNSApply
		}
	})
}

func dnsListenerAvailable(address string, mark int) bool {
	if address == "" || address == eng.desiredInbound.dnsListen {
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
