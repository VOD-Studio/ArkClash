package backup

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
)

const (
	maxArchive = 256 << 20
	maxTotal   = 1 << 30
	maxFile    = 64 << 20
	maxEntries = 10000
	manifest   = "manifest.json"
)

var (
	ErrInvalid = errors.New("backup_invalid")
	ErrVersion = errors.New("backup_version")
	ErrLimit   = errors.New("backup_limit")
	ErrIO      = errors.New("backup_io")
	ErrChanged = errors.New("backup_changed")
)

type entry struct {
	Path   string `json:"path"`
	Bytes  int64  `json:"bytes"`
	SHA256 string `json:"sha256"`
}

type index struct {
	Product       string  `json:"product"`
	FormatVersion int     `json:"formatVersion"`
	SchemaVersion int     `json:"schemaVersion"`
	Revision      string  `json:"revision"`
	Files         []entry `json:"files"`
}

func legalPath(name string) bool {
	if !filepath.IsLocal(name) || path.Clean(name) != name || strings.ContainsAny(name, "\\:\x00") {
		return false
	}
	for _, part := range strings.Split(name, "/") {
		if strings.HasPrefix(part, ".") || len(part) > 255 {
			return false
		}
	}
	return true
}

type budgetWriter struct {
	out  io.Writer
	left int64
}

func (w *budgetWriter) Write(p []byte) (int, error) {
	if int64(len(p)) >= w.left {
		return 0, ErrLimit
	}
	n, err := w.out.Write(p)
	w.left -= int64(n)
	return n, err
}

func scanFiles(root string) ([]string, error) {
	var names []string
	err := filepath.WalkDir(root, func(name string, item os.DirEntry, err error) error {
		if err != nil || item.IsDir() {
			return err
		}
		rel, err := filepath.Rel(root, name)
		if err != nil || !legalPath(rel) || !item.Type().IsRegular() {
			return ErrInvalid
		}
		names = append(names, rel)
		if len(names)+1 >= maxEntries {
			return ErrLimit
		}
		return nil
	})
	return names, err
}

func Pack(root, target, revision string) (err error) {
	names, err := scanFiles(root)
	if err != nil {
		return err
	}
	out, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer func() {
		err = errors.Join(err, out.Close())
		if err != nil {
			_ = os.Remove(target)
		}
	}()
	archive := zip.NewWriter(&budgetWriter{out: out, left: maxArchive})
	content := index{Product: "ArkClash", FormatVersion: 1, SchemaVersion: 1, Revision: revision, Files: []entry{}}
	var total int64
	for _, name := range names {
		if !portablePath(name) {
			return ErrInvalid
		}
		header := &zip.FileHeader{Name: name, Method: zip.Deflate}
		header.SetMode(0600)
		dst, err := archive.CreateHeader(header)
		if err != nil {
			return err
		}
		size, digest, err := packFile(root, name, dst)
		if err != nil {
			return err
		}
		total += size
		if total >= maxTotal {
			return ErrLimit
		}
		content.Files = append(content.Files, entry{Path: name, Bytes: size, SHA256: digest})
	}
	dst, err := archive.Create(manifest)
	if err != nil {
		return err
	}
	data, err := json.Marshal(content)
	if err != nil {
		return err
	}
	if total+int64(len(data)) >= maxTotal {
		return ErrLimit
	}
	if _, err := dst.Write(data); err != nil {
		return err
	}
	if err := archive.Close(); err != nil {
		return err
	}
	return out.Sync()
}

func packFile(root, name string, dst io.Writer) (int64, string, error) {
	if name != "dashboard.json" && !strings.HasSuffix(name, ".state.json") {
		return archiveFile(root, name, dst)
	}
	value, err := readObject(root, name)
	if err != nil {
		return 0, "", err
	}
	if name == "dashboard.json" {
		delete(value, "legacyPreferences")
	} else {
		delete(value, "error")
		delete(value, "failedAt")
		assign(value, "failures", 0)
	}
	data, err := json.Marshal(value)
	if err != nil {
		return 0, "", err
	}
	return copyDigest(dst, bytes.NewReader(data), maxFile)
}

func archiveFile(root, name string, dst io.Writer) (int64, string, error) {
	in, err := os.Open(filepath.Join(root, name))
	if err != nil {
		return 0, "", err
	}
	defer in.Close()
	return copyDigest(dst, in, maxFile)
}

func copyDigest(dst io.Writer, in io.Reader, max int64) (int64, string, error) {
	hash := sha256.New()
	n, err := io.Copy(io.MultiWriter(dst, hash), io.LimitReader(in, max))
	if n >= max {
		return n, "", ErrLimit
	}
	return n, hex.EncodeToString(hash.Sum(nil)), err
}

func openArchive(source string) (*os.File, *zip.Reader, error) {
	file, err := os.Open(source)
	if err != nil {
		return nil, nil, err
	}
	stat, err := file.Stat()
	if err == nil && stat.Size() >= maxArchive {
		err = ErrLimit
	}
	if err == nil {
		err = checkDirectoryBudget(file, stat.Size())
	}
	if err != nil {
		file.Close()
		return nil, nil, err
	}
	reader, err := zip.NewReader(file, stat.Size())
	if err != nil {
		file.Close()
		return nil, nil, ErrInvalid
	}
	return file, reader, nil
}

func checkDirectoryBudget(file *os.File, length int64) error {
	tail := make([]byte, min(length, 65535+22))
	if _, err := file.ReadAt(tail, length-int64(len(tail))); err != nil {
		return ErrInvalid
	}
	end := -1
	for n := len(tail) - 22; n >= 0; n-- {
		if bytes.Equal(tail[n:n+4], []byte("PK\x05\x06")) &&
			n+22+int(binary.LittleEndian.Uint16(tail[n+20:])) == len(tail) {
			end = n
			break
		}
	}
	if end < 0 {
		return ErrInvalid
	}
	record := tail[end:]
	count := int(binary.LittleEndian.Uint16(record[10:12]))
	if count >= maxEntries {
		return ErrLimit
	}
	disk := binary.LittleEndian.Uint32(record[4:8])
	offset := int64(binary.LittleEndian.Uint32(record[16:20]))
	size := int64(binary.LittleEndian.Uint32(record[12:16]))
	if disk != 0 || int(binary.LittleEndian.Uint16(record[8:10])) != count ||
		offset+size != length-int64(len(tail))+int64(end) {
		return ErrInvalid
	}
	header := make([]byte, 46)
	limit := offset + size
	for range count {
		if offset+46 > limit {
			return ErrInvalid
		}
		if _, err := file.ReadAt(header, offset); err != nil || !bytes.Equal(header[:4], []byte("PK\x01\x02")) {
			return ErrInvalid
		}
		offset += 46 + int64(binary.LittleEndian.Uint16(header[28:30])) +
			int64(binary.LittleEndian.Uint16(header[30:32])) + int64(binary.LittleEndian.Uint16(header[32:34]))
	}
	if offset != limit {
		return ErrInvalid
	}
	return nil
}

func archiveIndex(reader *zip.Reader) (map[string]*zip.File, index, error) {
	files := map[string]*zip.File{}
	var total uint64
	for _, item := range reader.File {
		name := item.Name
		if !legalPath(name) || (name != manifest && !portablePath(name)) || !item.Mode().IsRegular() || files[name] != nil {
			return nil, index{}, ErrInvalid
		}
		if item.UncompressedSize64 >= maxFile {
			return nil, index{}, ErrLimit
		}
		total += item.UncompressedSize64
		if total >= maxTotal {
			return nil, index{}, ErrLimit
		}
		files[name] = item
	}
	item := files[manifest]
	if item == nil || item.UncompressedSize64 >= 4<<20 {
		return nil, index{}, ErrInvalid
	}
	in, err := item.Open()
	if err != nil {
		return nil, index{}, ErrInvalid
	}
	defer in.Close()
	data, err := io.ReadAll(io.LimitReader(in, 4<<20))
	var result index
	if err != nil || len(data) >= 4<<20 || json.Unmarshal(data, &result) != nil || result.Product != "ArkClash" {
		return nil, index{}, ErrInvalid
	}
	if result.FormatVersion != 1 || result.SchemaVersion != 1 {
		return nil, index{}, ErrVersion
	}
	delete(files, manifest)
	if result.Files == nil || len(result.Files) != len(files) {
		return nil, index{}, ErrInvalid
	}
	for _, name := range requiredFiles {
		if files[name] == nil {
			return nil, index{}, ErrInvalid
		}
	}
	return files, result, nil
}

func Unpack(source, root string) error {
	file, reader, err := openArchive(source)
	if err != nil {
		return err
	}
	defer file.Close()
	files, content, err := archiveIndex(reader)
	if err != nil {
		return err
	}
	for _, item := range content.Files {
		in := files[item.Path]
		if in == nil || item.Bytes < 0 || uint64(item.Bytes) != in.UncompressedSize64 {
			return ErrInvalid
		}
		if err := extract(root, item, in); err != nil {
			return err
		}
		delete(files, item.Path)
	}
	return nil
}

func extract(root string, item entry, in *zip.File) error {
	source, err := in.Open()
	if err != nil {
		return ErrInvalid
	}
	defer source.Close()
	target := filepath.Join(root, item.Path)
	if err := os.MkdirAll(filepath.Dir(target), 0700); err != nil {
		return err
	}
	out, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	size, digest, err := copyDigest(out, source, min(item.Bytes+1, maxFile))
	closeErr := out.Close()
	if err != nil || size != item.Bytes || digest != item.SHA256 {
		return ErrInvalid
	}
	return closeErr
}

func portablePath(name string) bool {
	if name == "profile-views.json" || slices.Contains(requiredFiles, name) || slices.Contains(settingFiles, name) {
		return true
	}
	if rest, ok := strings.CutPrefix(name, "rule-sets/"); ok {
		stem, ok := strings.CutSuffix(rest, ".source")
		return ok && legalPath(stem) && !strings.Contains(stem, "/")
	}
	for _, suffix := range []string{".yaml", ".selected.json", ".state.json"} {
		if id, ok := strings.CutSuffix(name, suffix); ok {
			return validID(id)
		}
	}
	return false
}
