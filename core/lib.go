// Package main builds libclash.so, the mihomo core loaded by ArkClash's
// VpnExtensionAbility. The exported C API is declared in arkclash.h; keep the
// two in sync.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"errors"
	"os"
	"sync"
	"unsafe"

	"github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/log"
)

// startOptions is the JSON payload passed to ArkClashStart. JSON keeps the C
// ABI stable while options grow.
type startOptions struct {
	HomeDir    string `json:"homeDir"`
	ConfigPath string `json:"configPath"`
	TunFd      int    `json:"tunFd"`
	Controller string `json:"controller"`
	Secret     string `json:"secret"`
	Stack      string `json:"stack"`
}

var (
	mu      sync.Mutex
	running bool
)

func start(opts startOptions) error {
	mu.Lock()
	defer mu.Unlock()

	if running {
		return errors.New("core is already running")
	}
	if opts.TunFd <= 0 {
		return errors.New("invalid tun fd")
	}

	constant.SetHomeDir(opts.HomeDir)
	constant.SetConfig(opts.ConfigPath)

	buf, err := os.ReadFile(opts.ConfigPath)
	if err != nil {
		return err
	}
	rawCfg, err := config.UnmarshalRawConfig(buf)
	if err != nil {
		return err
	}
	applyOverrides(rawCfg, opts)

	cfg, err := config.ParseRawConfig(rawCfg)
	if err != nil {
		return err
	}
	hub.ApplyConfig(cfg)

	if err := startTun(opts.TunFd, opts.Stack); err != nil {
		executor.Shutdown()
		return err
	}

	running = true
	log.Infoln("[ArkClash] core started")
	return nil
}

// applyOverrides forces the settings ArkClash owns, whatever the profile says.
func applyOverrides(rawCfg *config.RawConfig, opts startOptions) {
	// The TUN is created by VpnExtensionAbility and handed over as an fd, so the
	// profile must not try to create its own.
	rawCfg.Tun.Enable = false

	// The UI process drives the core over this controller only.
	rawCfg.ExternalController = opts.Controller
	rawCfg.Secret = opts.Secret
	rawCfg.ExternalControllerTLS = ""
	rawCfg.ExternalControllerUnix = ""
	rawCfg.ExternalControllerPipe = ""
	rawCfg.ExternalUI = ""

	// Process lookup scans /proc for every connection and cannot map to apps on
	// HarmonyOS anyway; it only costs battery.
	rawCfg.FindProcessMode = process.FindProcessOff

	// DNS from the TUN is hijacked into mihomo, so the resolver has to be on.
	if !rawCfg.DNS.Enable {
		rawCfg.DNS.Enable = true
		rawCfg.DNS.EnhancedMode = constant.DNSFakeIP
	}
}

func stop() {
	mu.Lock()
	defer mu.Unlock()

	if !running {
		return
	}
	stopTun()
	executor.Shutdown()
	running = false
}

func errorString(err error) *C.char {
	if err == nil {
		return nil
	}
	return C.CString(err.Error())
}

// ArkClashStart starts the core. It returns NULL on success or an error
// message that the caller must release with ArkClashFree.
//
//export ArkClashStart
func ArkClashStart(optionsJSON *C.char) *C.char {
	var opts startOptions
	if err := json.Unmarshal([]byte(C.GoString(optionsJSON)), &opts); err != nil {
		return errorString(err)
	}
	return errorString(start(opts))
}

//export ArkClashStop
func ArkClashStop() {
	stop()
}

// ArkClashVersion returns the mihomo version. Release it with ArkClashFree.
//
//export ArkClashVersion
func ArkClashVersion() *C.char {
	return C.CString(constant.Version)
}

//export ArkClashFree
func ArkClashFree(p *C.char) {
	C.free(unsafe.Pointer(p))
}

func main() {}
