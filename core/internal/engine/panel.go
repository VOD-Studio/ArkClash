package engine

import (
	"context"
	"crypto/subtle"
	"errors"
	"net"
	"strconv"
	"strings"
	"time"

	corecfg "github.com/VOD-Studio/ArkClash/core/internal/config"
	"github.com/VOD-Studio/ArkClash/core/internal/ctrl"
	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/listener"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
)

type panelController struct {
	secret   string
	listener net.Listener
	server   *http.Server
}

func (e *Engine) setPanelControllerLocked(secret string) error {
	return e.changePanelControllerLocked(e.panelAddressLocked(), secret)
}

func (e *Engine) changePanelControllerLocked(address, secret string) error {
	if e.panel != nil {
		if e.panel.secret == secret {
			return nil
		}
		old := e.panel
		e.panel = nil
		// 被 HTTP 劫持的 WebSocket 也由监听器持有，换密钥时一起关闭。
		_ = old.listener.Close()
		_ = old.server.Close()
		if secret != "" {
			if err := e.startPanelControllerLocked(address, secret); err != nil {
				_ = e.startPanelControllerLocked(address, old.secret)
				return err
			}
			return nil
		}
	}
	if secret != "" {
		return e.startPanelControllerLocked(address, secret)
	}
	return nil
}

func (e *Engine) startPanelControllerLocked(address, secret string) error {
	lc := inbound.NewListenConfig()
	socket, err := lc.Listen(context.Background(), "tcp", address)
	if err != nil {
		return corecfg.ErrGeneralPanel
	}
	server := &http.Server{Handler: e.panelHandler(secret), ReadHeaderTimeout: 5 * time.Second, MaxHeaderBytes: 16 << 10}
	e.panel = &panelController{secret: secret, listener: socket, server: server}
	go func() { _ = server.Serve(socket) }()
	return nil
}

func (e *Engine) panelHandler(secret string) http.Handler {
	readOnly := route.ArkClashPanelRouter(secret)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := strings.TrimSuffix(r.URL.Path, "/")
		segments := strings.Split(strings.TrimPrefix(path, "/"), "/")
		method := r.Method
		if method == http.MethodOptions {
			method = r.Header.Get("Access-Control-Request-Method")
		}
		if method == http.MethodGet && panelReadPath(path, segments) {
			readOnly.ServeHTTP(w, r)
			return
		}
		configs := path == "/configs" && method == http.MethodGet
		selection := len(segments) == 2 && segments[0] == "proxies" &&
			(method == http.MethodPut || method == http.MethodDelete)
		if configs || selection {
			if origin := r.Header.Get("Origin"); origin != "" {
				w.Header().Set("Access-Control-Allow-Origin", "*")
				w.Header().Set("Access-Control-Allow-Private-Network", "true")
				w.Header().Set("Access-Control-Allow-Methods", "GET, PUT, DELETE")
				w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
			}
			if r.Method == http.MethodOptions {
				render.NoContent(w, r)
				return
			}
			if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+secret)) != 1 {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			if configs {
				ports := listener.GetPorts()
				render.JSON(w, r, render.M{"mode": tunnel.Mode(), "allow-lan": listener.AllowLan(),
					"log-level": log.Level(), "port": ports.Port, "socks-port": ports.SocksPort,
					"mixed-port": ports.MixedPort, "redir-port": ports.RedirPort, "tproxy-port": ports.TProxyPort})
				return
			}
			if status, err := e.WithPortableMutation(false, func() {
				e.selectPanelProxy(w, r, segments[1])
			}); err != nil {
				ctrl.WriteError(w, r, status, err)
			}
			return
		}
		http.NotFound(w, r)
	})
}

func panelReadPath(path string, segments []string) bool {
	switch path {
	case "", "/version", "/traffic", "/memory", "/rules", "/connections", "/proxies",
		"/providers/proxies", "/providers/rules", "/group":
		return true
	}
	if len(segments) == 2 {
		return segments[1] != "" && (segments[0] == "proxies" || segments[0] == "group")
	}
	return len(segments) == 3 && segments[0] == "providers" &&
		(segments[1] == "proxies" || segments[1] == "rules") && segments[2] != ""
}

func (e *Engine) selectPanelProxy(w http.ResponseWriter, r *http.Request, group string) {
	var body struct {
		Name string `json:"name"`
	}
	clear := r.Method == http.MethodDelete
	if !clear && corecfg.DecodeSettings(http.MaxBytesReader(w, r.Body, 8192), &body) != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	var (
		unauthorized bool
		result       SelectionResult
		err          error
	)
	_ = e.withState(func(tx *stateTx) error {
		if e.panel == nil || subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")),
			[]byte("Bearer "+e.panel.secret)) != 1 {
			unauthorized = true
			return nil
		}
		request := SelectionRequest{Profile: e.current.Profile, Group: group, Name: body.Name, ClearPin: clear,
			CloseConnections: true, OperationID: "panel-" + strconv.FormatUint(e.panelOpSeq.Add(1), 16),
			ExpectedBootID: e.bootID, ExpectedRevision: e.configRevision}
		if !clear {
			for _, member := range e.currentProxyGraphLocked().Members[group] {
				if member.Name == body.Name && member.Selectable {
					request.NodeID = member.ID
					break
				}
			}
		}
		result, err = e.commitSelectionLocked(request)
		return nil
	})
	if unauthorized {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	if err != nil {
		ctrl.WriteError(w, r, http.StatusConflict, err)
		return
	}
	if result.CleanupFailed {
		ctrl.WriteError(w, r, http.StatusInternalServerError, errors.New("selection_cleanup_failed"))
		return
	}
	render.NoContent(w, r)
}
