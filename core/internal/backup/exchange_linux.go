//go:build linux

package backup

import (
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

func Commit(home, target string) error {
	if err := unix.Renameat2(unix.AT_FDCWD, filepath.Join(home, "profiles"), unix.AT_FDCWD, target,
		unix.RENAME_EXCHANGE); err != nil {
		return err
	}
	syncDir(home)
	syncDir(filepath.Dir(target))
	return nil
}

func syncDir(name string) {
	if dir, err := os.Open(name); err == nil {
		_ = dir.Sync()
		_ = dir.Close()
	}
}
