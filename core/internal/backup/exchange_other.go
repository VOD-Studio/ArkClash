//go:build !linux

package backup

func Commit(home, target string) error { return ErrIO }
