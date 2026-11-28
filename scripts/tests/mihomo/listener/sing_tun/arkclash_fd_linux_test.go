//go:build linux

package sing_tun

import (
	"os"
	"strconv"
	"strings"
	"testing"

	C "github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/tunnel"
	tun "github.com/metacubex/sing-tun"
	"golang.org/x/sys/unix"
)

func arkClashPipeFDs(t *testing.T, fd int) map[int]bool {
	t.Helper()
	target, err := os.Readlink("/proc/self/fd/" + strconv.Itoa(fd))
	if err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir("/proc/self/fd")
	if err != nil {
		t.Fatal(err)
	}
	result := map[int]bool{}
	for _, entry := range entries {
		path, _ := os.Readlink("/proc/self/fd/" + entry.Name())
		if path == target {
			n, _ := strconv.Atoi(entry.Name())
			result[n] = true
		}
	}
	return result
}

func TestArkClashExternalFDOwnership(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	defer w.Close()
	fd := int(r.Fd())
	before := arkClashPipeFDs(t, fd)
	device, err := tunNew(tun.Options{FileDescriptor: fd})
	if err != nil {
		t.Fatal(err)
	}
	duplicate := -1
	for n := range arkClashPipeFDs(t, fd) {
		if !before[n] {
			duplicate = n
		}
	}
	if duplicate < 0 {
		t.Fatal("external fd was not duplicated")
	}
	flags, err := unix.FcntlInt(uintptr(duplicate), unix.F_GETFD, 0)
	if err != nil || flags&unix.FD_CLOEXEC == 0 {
		t.Fatalf("duplicate is not cloexec: %d, %v", flags, err)
	}
	if err := device.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := unix.FcntlInt(uintptr(fd), unix.F_GETFD, 0); err != nil {
		t.Fatalf("platform fd closed: %v", err)
	}
	if _, err := unix.FcntlInt(uintptr(duplicate), unix.F_GETFD, 0); err != unix.EBADF {
		t.Fatalf("duplicate still open: %v", err)
	}
	reused, err := unix.FcntlInt(uintptr(fd), unix.F_DUPFD_CLOEXEC, duplicate)
	if err != nil {
		t.Fatal(err)
	}
	defer unix.Close(reused)
	if reused != duplicate {
		t.Fatalf("could not reuse descriptor: %d != %d", reused, duplicate)
	}
	_ = device.Close()
	if _, err := unix.FcntlInt(uintptr(reused), unix.F_GETFD, 0); err != nil {
		t.Fatalf("second close touched reused fd: %v", err)
	}
}

func TestArkClashStackConstructorRollback(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	defer w.Close()
	fd := int(r.Fd())
	before := arkClashPipeFDs(t, fd)
	options := LC.Tun{Enable: true, Device: "arkclash-test", FileDescriptor: fd, MTU: 1500, Stack: C.TUNStack(255)}
	for i := 0; i < 3; i++ {
		listener, err := New(options, tunnel.Tunnel)
		if err == nil || !strings.Contains(err.Error(), "unknown stack") {
			if listener != nil {
				_ = listener.Close()
			}
			t.Fatalf("expected real stack constructor failure, got %v", err)
		}
		after := arkClashPipeFDs(t, fd)
		if len(after) != len(before) {
			t.Fatalf("rollback leaked duplicate: before %v after %v", before, after)
		}
		for n := range before {
			if !after[n] {
				t.Fatalf("rollback closed platform descriptor %d", n)
			}
		}
	}
}
