package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"

	"github.com/VOD-Studio/ArkClash/core/internal/backup"
)

type request struct {
	Action   string             `json:"action"`
	Home     string             `json:"home"`
	Work     string             `json:"work"`
	All      bool               `json:"all"`
	Replace  bool               `json:"replace"`
	Revision string             `json:"revision"`
	DAV      backup.DAVSettings `json:"dav"`
}

type response struct {
	Revision string `json:"revision,omitempty"`
	Error    string `json:"error,omitempty"`
	Plan     any    `json:"plan,omitempty"`
}

func execute(req request) (response, error) {
	archive, err := backup.WorkspaceArchive(req.Home, req.Work)
	if err != nil {
		return response{}, err
	}
	root := filepath.Dir(archive)
	previous := filepath.Join(root, "previous")
	imported := filepath.Join(root, "imported")
	target := filepath.Join(root, "next")
	switch req.Action {
	case "snapshot":
		rev, err := backup.Snapshot(req.Home, previous, req.All)
		return response{Revision: rev}, err
	case "pack":
		return response{}, backup.Pack(previous, archive, req.Revision)
	case "unpack":
		return response{}, backup.Unpack(archive, imported)
	case "plan":
		plan, err := backup.Plan(previous, imported, target, req.All, req.Replace)
		return response{Plan: plan}, err
	case "seal":
		return response{}, backup.Seal(target, req.Revision)
	case "prepare":
		return response{}, backup.PrepareCommit(req.Home, previous, filepath.Join(root, "fresh"))
	case "commit":
		return response{}, backup.Commit(req.Home, target)
	case "probe", "upload", "download":
		transport := backup.DirectTransport()
		defer transport.CloseIdleConnections()
		return response{}, backup.DAV(context.Background(), transport, req.DAV, req.Action, archive)
	default:
		return response{}, backup.ErrIO
	}
}

func userError(err error) string {
	if err == nil {
		return ""
	}
	for _, sentinel := range []error{backup.ErrInvalid, backup.ErrVersion, backup.ErrLimit, backup.ErrChanged,
		backup.ErrIO, backup.ErrDAVSettings, backup.ErrDAVResponse, backup.ErrDAVNetwork} {
		if errors.Is(err, sentinel) {
			return sentinel.Error()
		}
	}
	if message := err.Error(); strings.HasPrefix(message, "backup_dav_http_") {
		return strings.Split(message, "\n")[0]
	}
	var pathErr *os.PathError
	var linkErr *os.LinkError
	var errno syscall.Errno
	if errors.As(err, &errno) {
		if errors.As(err, &pathErr) {
			return fmt.Sprintf("backup_io_%s_%d", pathErr.Op, errno)
		}
		if errors.As(err, &linkErr) {
			return fmt.Sprintf("backup_io_%s_%d", linkErr.Op, errno)
		}
		return fmt.Sprintf("backup_io_%d", errno)
	}
	return backup.ErrIO.Error()
}

//export ArkStoreRun
func ArkStoreRun(raw *C.char) *C.char {
	var req request
	var out response
	if err := json.Unmarshal([]byte(C.GoString(raw)), &req); err != nil {
		out.Error = backup.ErrInvalid.Error()
	} else {
		result, err := execute(req)
		out = result
		out.Error = userError(err)
	}
	data, _ := json.Marshal(out)
	return C.CString(string(data))
}

//export ArkStoreFree
func ArkStoreFree(raw *C.char) { C.free(unsafe.Pointer(raw)) }

func main() {}
