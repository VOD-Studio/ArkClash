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
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	"github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/listener"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
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
	// 以下由 VPN 进程从 runtime.json 和配置列表（entry/src/main/ets/shared/）读出后传入。
	Profile  string `json:"profile"`  // 正在运行的配置的编号
	Mode     string `json:"mode"`     // 'rule' | 'global' | 'direct'，空串 = 用配置里的值
	AllowLan *bool  `json:"allowLan"` // nil = 用配置里的值
	// 实验：只加载配置不接隧道，之后用 ArkClashAttachTun 接入。
	Standby bool `json:"standby"`
}

var (
	mu      sync.Mutex
	running bool
	// 本次启动的参数，热切换和 PATCH /arkclash/configs 会更新其中的配置路径、编号、模式和局域网代理。
	current startOptions
	// 正在运行的配置编号，nil = 没在运行。ArkTS 主线程会同步读它，不能等 mu（热切换可能要几秒）。
	runningID atomic.Pointer[string]
)

func start(opts startOptions) error {
	mu.Lock()
	defer mu.Unlock()

	if running {
		return errors.New("core is already running")
	}
	if opts.TunFd <= 0 && !opts.Standby {
		return errors.New("invalid tun fd")
	}

	constant.SetHomeDir(opts.HomeDir)
	constant.SetConfig(opts.ConfigPath)

	t0 := time.Now()
	cfg, err := parseConfig(opts.ConfigPath, opts)
	if err != nil {
		return err
	}
	t1 := time.Now()
	hub.ApplyConfig(cfg)
	t2 := time.Now()

	if !opts.Standby {
		if err := startTun(opts.TunFd, opts.Stack); err != nil {
			executor.Shutdown()
			return err
		}
	}
	expLog("event=core-start standby=%t parse_ms=%d apply_ms=%d tun_ms=%d", opts.Standby,
		t1.Sub(t0).Milliseconds(), t2.Sub(t1).Milliseconds(), time.Since(t2).Milliseconds())
	startExpSocket(opts.HomeDir)

	running = true
	current = opts
	runningID.Store(&opts.Profile)
	log.Infoln("[ArkClash] core started")
	return nil
}

func parseConfig(path string, opts startOptions) (*config.Config, error) {
	buf, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	rawCfg, err := config.UnmarshalRawConfig(buf)
	if err != nil {
		return nil, err
	}
	applyOverrides(rawCfg, opts)
	return config.ParseRawConfig(rawCfg)
}

// reload 是热切换：解析 path，成功后换用新配置，profile 记为正在运行的配置。
// 只调 executor.ApplyConfig，不走 hub.ApplyConfig：后者的 applyRoute 每次都会关掉 controller
// 再重开，掐断发起热切换的请求和界面的 WebSocket（ADR-0010）。controller 的地址和 secret
// 由 applyOverrides 固定，不需要重建。改 start 的解析和应用流程时，这里要一起看。
func reload(path, profile string) error {
	mu.Lock()
	defer mu.Unlock()

	if !running {
		return errors.New("core is not running")
	}
	if err := checkProfilePath(path); err != nil {
		return err
	}
	cfg, err := parseConfig(path, current)
	if err != nil {
		return err
	}
	constant.SetConfig(path)
	executor.ApplyConfig(cfg, true)
	current.ConfigPath = path
	current.Profile = profile
	runningID.Store(&profile)
	log.Infoln("[ArkClash] reloaded profile %s", profile)
	emit(reloadedEvent{Type: "reloaded", Profile: profile})
	return nil
}

// 推给界面的「热切换完成」事件，格式和 entry/src/main/ets/client/ 里的解析一致。
type reloadedEvent struct {
	Type    string `json:"type"`
	Profile string `json:"profile"`
}

// 热切换只接受配置目录下的文件，见 entry/src/main/ets/shared/profiles/Store.ets。
func checkProfilePath(path string) error {
	dir := filepath.Join(current.HomeDir, "profiles") + string(filepath.Separator)
	if !strings.HasPrefix(filepath.Clean(path), dir) {
		return fmt.Errorf("profile must be under %s", dir)
	}
	return nil
}

func runningProfile() (string, bool) {
	p := runningID.Load()
	if p == nil {
		return "", false
	}
	return *p, true
}

// setRuntimeOptions 立即修改出站模式和局域网代理，并记下来供之后的热切换使用。
func setRuntimeOptions(mode *string, allowLan *bool) error {
	mu.Lock()
	defer mu.Unlock()

	if !running {
		return errors.New("core is not running")
	}
	if mode != nil {
		m, ok := tunnel.ModeMapping[strings.ToLower(*mode)]
		if !ok {
			return fmt.Errorf("unknown mode %q", *mode)
		}
		tunnel.SetMode(m)
		current.Mode = *mode
	}
	if allowLan != nil {
		listener.SetAllowLan(*allowLan)
		v := *allowLan
		current.AllowLan = &v
	}
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

	// 用户在界面上选过的出站模式和局域网代理优先于配置，热切换后不会被新配置改回去（ADR-0010）。
	if m, ok := tunnel.ModeMapping[strings.ToLower(opts.Mode)]; ok {
		rawCfg.Mode = m
	}
	if opts.AllowLan != nil {
		rawCfg.AllowLan = *opts.AllowLan
	}
}

func stop() {
	mu.Lock()
	defer mu.Unlock()

	if !running {
		return
	}
	stopExpSocket()
	stopTun()
	executor.Shutdown()
	running = false
	current = startOptions{}
	runningID.Store(nil)
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

// ArkClashReload 热切换到 path 指向的配置，profile 是它的编号。成功返回 NULL，
// 否则返回错误信息，调用方用 ArkClashFree 释放。
//
//export ArkClashReload
func ArkClashReload(path, profile *C.char) *C.char {
	return errorString(reload(C.GoString(path), C.GoString(profile)))
}

// ArkClashRunningProfile 返回正在运行的配置编号，没在运行时是空串。用 ArkClashFree 释放。
//
//export ArkClashRunningProfile
func ArkClashRunningProfile() *C.char {
	profile, _ := runningProfile()
	return C.CString(profile)
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
