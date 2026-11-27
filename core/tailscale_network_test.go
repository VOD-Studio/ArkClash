package main

import (
	"errors"
	"net"
	"os"
	"os/exec"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/tailscale/net/netmon"
	"github.com/metacubex/tailscale/util/eventbus"
)

func TestTailscaleDefaultNetwork(t *testing.T) {
	// netmon 的平台钩子按进程安装。用独立进程隔开宿主的其他拨号用例。
	const childEnv = "ARKCLASH_TEST_TAILNET_NETWORK"
	if os.Getenv(childEnv) == "" {
		cmd := exec.Command(os.Args[0], "-test.run=^TestTailscaleDefaultNetwork$", "-test.timeout=15s")
		cmd.Env = append(os.Environ(), childEnv+"=1")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("%v\n%s", err, out)
		}
		return
	}
	var watches tailscaleNetworkWatches
	var name atomic.Value
	name.Store("")
	interfaces := func() ([]netmon.Interface, error) {
		n := name.Load().(string)
		if n == "" {
			return nil, nil
		}
		return []netmon.Interface{{
			Interface: &net.Interface{Name: n, Index: 3, Flags: net.FlagUp},
			AltAddrs:  []net.Addr{&net.IPNet{IP: net.IPv4(192, 0, 2, 5), Mask: net.CIDRMask(24, 32)}},
		}}, nil
	}
	registrations, releases := 0, 0
	netmon.SetArkClashNetwork(interfaces, func(notify func()) (func() error, error) {
		return watches.subscribe(notify, func() (uint32, error) {
			registrations++
			watches.changed()
			return 42, nil
		}, func(id uint32) error {
			if id != 42 {
				t.Errorf("released callback %d", id)
			}
			releases++
			return nil
		})
	})
	bus := eventbus.New()
	defer bus.Close()
	newMonitor := func() *netmon.Monitor {
		m, err := netmon.New(bus, t.Logf)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = m.Close() })
		return m
	}
	first, second := newMonitor(), newMonitor()
	if first.InterfaceState().AnyInterfaceUp() || registrations != 1 {
		t.Fatal("offline start or shared callback registration failed")
	}
	updates := make(chan *netmon.State, 8)
	first.RegisterChangeCallback(func(d *netmon.ChangeDelta) { updates <- d.CurrentState() })
	first.Start()
	for _, n := range []string{"wlan0", "rmnet0", ""} {
		name.Store(n)
		watches.changed()
		select {
		case s := <-updates:
			if s.DefaultRouteInterface != n || s.HaveV4 != (n != "") {
				t.Fatalf("unexpected route or addresses: %s", s)
			}
		case <-time.After(4 * time.Second):
			t.Fatalf("missing change to %q", n)
		}
	}
	if err := second.Close(); err != nil || releases != 0 {
		t.Fatal("closing an unused monitor released a shared registration")
	}
	if err := first.Close(); err != nil || releases != 1 {
		t.Fatal("last monitor did not release registration")
	}
}

func TestTailscaleNetworkRegistrationFailure(t *testing.T) {
	var watches tailscaleNetworkWatches
	wanted := errors.New("network service unavailable")
	builds, releases, deliveries := 0, 0, 0
	acquire := func() (func() error, error) {
		return watches.subscribe(func() { deliveries++ }, func() (uint32, error) {
			builds++
			if builds == 1 {
				return 0, wanted
			}
			return 5, nil
		}, func(uint32) error {
			releases++
			if releases == 1 {
				return wanted
			}
			return nil
		})
	}
	if _, err := acquire(); !errors.Is(err, wanted) {
		t.Fatal("registration failure lost")
	}
	stop, err := acquire()
	if err != nil {
		t.Fatal(err)
	}
	watches.changed()
	if err := stop(); !errors.Is(err, wanted) {
		t.Fatal("unregistration failure lost")
	}
	watches.changed()
	stop, err = acquire()
	if err != nil {
		t.Fatal(err)
	}
	if err := stop(); err != nil || builds != 2 || releases != 2 || deliveries != 1 {
		t.Fatalf("register=%d release=%d delivered=%d err=%v", builds, releases, deliveries, err)
	}
}
