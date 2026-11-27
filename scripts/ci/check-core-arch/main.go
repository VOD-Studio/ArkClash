// 检查 core/ 的 Go 架构边界：构建标签隔离、Cgo 范围、internal/* DAG 白名单（未登记即失败）、零 mihomo 边界、init() 白名单、C ABI 导出位置及命名约束。
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
)

const (
	rootPkg        = "github.com/VOD-Studio/ArkClash/core"
	backupStorePkg = rootPkg + "/backupstore"
	internalPrefix = rootPkg + "/internal/"
	backupPkg      = internalPrefix + "backup"
	scriptPkg      = internalPrefix + "script"
	proxylinkPkg   = internalPrefix + "proxylink"
	rulesetPkg     = internalPrefix + "ruleset"
	mihomoPrefix   = "github.com/metacubex/mihomo"
)

var (
	ohosCgoFiles = []string{"hilog.go", "lib.go", "socket.go", "system_dns.go", "tailscale_network.go"}
	ohosAllFiles = []string{"hilog.go", "lib.go", "loopback.go", "socket.go", "system_dns.go", "tailscale_network.go"}
	hostCgoPkgs  = map[string]bool{
		backupStorePkg: true,
		scriptPkg:      true,
	}
	zeroMihomoPkgs = []string{backupStorePkg, backupPkg, scriptPkg}
	// internal/* 包依赖白名单（未登记即失败）：只列出每个子包允许依赖的其他 core/internal/* 包。
	allowedInternalDeps = map[string][]string{
		backupPkg:    nil,
		scriptPkg:    nil,
		proxylinkPkg: nil,
		rulesetPkg:   nil,
	}
	allowedInitFiles = map[string]bool{
		"api.go":               true,
		"hilog.go":             true,
		"loopback.go":          true,
		"socket.go":            true,
		"system_dns.go":        true,
		"tailscale_network.go": true,
	}
)

type listedPackage struct {
	ImportPath string   `json:"ImportPath"`
	GoFiles    []string `json:"GoFiles"`
	CgoFiles   []string `json:"CgoFiles"`
	Imports    []string `json:"Imports"`
	Deps       []string `json:"Deps"`
}

func goList(coreDir, modfile, tags string, extraEnv ...string) (map[string]listedPackage, error) {
	args := []string{"list", "-json", "-mod=readonly"}
	if modfile != "" {
		args = append(args, "-modfile", modfile)
	}
	if tags != "" {
		args = append(args, "-tags", tags)
	}
	args = append(args, "./...")

	cmd := exec.Command("go", args...)
	cmd.Dir = coreDir
	cmd.Env = append(os.Environ(), extraEnv...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("go %s 失败：%w\n%s", strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}

	pkgs := make(map[string]listedPackage)
	dec := json.NewDecoder(&stdout)
	for {
		var pkg listedPackage
		if err := dec.Decode(&pkg); err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return nil, fmt.Errorf("解析 go list 输出失败：%w", err)
		}
		pkgs[pkg.ImportPath] = pkg
	}
	return pkgs, nil
}

func hasMihomoDep(pkg listedPackage) (string, bool) {
	for _, dep := range pkg.Imports {
		if dep == mihomoPrefix || strings.HasPrefix(dep, mihomoPrefix+"/") {
			return dep, true
		}
	}
	for _, dep := range pkg.Deps {
		if dep == mihomoPrefix || strings.HasPrefix(dep, mihomoPrefix+"/") {
			return dep, true
		}
	}
	return "", false
}

func checkPackageDAG(label string, pkgs map[string]listedPackage) []string {
	var problems []string
	var paths []string
	for path := range pkgs {
		paths = append(paths, path)
	}
	slices.Sort(paths)

	for _, path := range paths {
		pkg := pkgs[path]
		switch {
		case path == rootPkg:
			// 根包可以装配全部已登记的 internal/* 包。
		case path == backupStorePkg:
			for _, imp := range pkg.Imports {
				if strings.HasPrefix(imp, internalPrefix) && imp != backupPkg {
					problems = append(problems, fmt.Sprintf("%s 构建下 %s 只允许依赖 %s，禁止依赖 %s", label, path, backupPkg, imp))
				}
			}
		case strings.HasPrefix(path, internalPrefix):
			allowed, registered := allowedInternalDeps[path]
			if !registered {
				problems = append(problems, fmt.Sprintf("%s 构建出现未登记的内部包 %s，先在 ADR/architecture.md 和 check-core-arch 白名单里登记", label, path))
				continue
			}
			for _, imp := range pkg.Imports {
				if strings.HasPrefix(imp, internalPrefix) && !slices.Contains(allowed, imp) {
					problems = append(problems, fmt.Sprintf("%s 构建下 %s 不允许依赖 %s（允许列表：%v）", label, path, imp, allowed))
				}
			}
		default:
			problems = append(problems, fmt.Sprintf("%s 构建出现未登记的包路径 %s", label, path))
		}
	}

	// 正向核对已登记的 internal/* 包全部存在，避免白名单陈旧。
	var registered []string
	for path := range allowedInternalDeps {
		registered = append(registered, path)
	}
	slices.Sort(registered)
	for _, path := range registered {
		if _, ok := pkgs[path]; !ok {
			problems = append(problems, fmt.Sprintf("%s 构建缺少已登记的内部包 %s", label, path))
		}
	}
	return problems
}

func checkPackages(coreDir, modfile string) []string {
	var problems []string

	// 1. 宿主标签（不带 ohos）：根包不得有 Cgo，且只能由 backupstore 与 internal/script 使用 Cgo。
	hostPkgs, err := goList(coreDir, modfile, "with_gvisor", "CGO_ENABLED=1")
	if err != nil {
		return []string{err.Error()}
	}
	rootHost, ok := hostPkgs[rootPkg]
	if !ok {
		problems = append(problems, "宿主 go list 缺少根包 "+rootPkg)
	} else {
		if len(rootHost.CgoFiles) > 0 {
			problems = append(problems, fmt.Sprintf("宿主构建下 core 根包不允许出现 CgoFiles：%v", rootHost.CgoFiles))
		}
		included := append(slices.Clone(rootHost.GoFiles), rootHost.CgoFiles...)
		for _, forbidden := range ohosAllFiles {
			if slices.Contains(included, forbidden) {
				problems = append(problems, fmt.Sprintf("宿主构建（无 ohos 标签）意外包含了平台文件：%s", forbidden))
			}
		}
	}
	for path, pkg := range hostPkgs {
		if len(pkg.CgoFiles) > 0 && !hostCgoPkgs[path] {
			problems = append(problems, fmt.Sprintf("宿主构建下非白名单包 %s 存在 CgoFiles：%v", path, pkg.CgoFiles))
		}
	}

	// 2. OHOS 目标标签（with_gvisor,ohos）：正向核对全部 6 个平台/ABI 文件被包含，避免标签拼错静默跳过。
	ohosPkgs, err := goList(coreDir, modfile, "with_gvisor,ohos", "CGO_ENABLED=1", "GOOS=linux", "GOARCH=arm64")
	if err != nil {
		return append(problems, err.Error())
	}
	rootOhos, ok := ohosPkgs[rootPkg]
	if !ok {
		problems = append(problems, "ohos go list 缺少根包 "+rootPkg)
	} else {
		gotCgo := slices.Clone(rootOhos.CgoFiles)
		slices.Sort(gotCgo)
		wantCgo := slices.Clone(ohosCgoFiles)
		slices.Sort(wantCgo)
		if !slices.Equal(gotCgo, wantCgo) {
			problems = append(problems, fmt.Sprintf("ohos 构建下 core 根包 CgoFiles=%v，预期=%v", gotCgo, wantCgo))
		}
		if !slices.Contains(rootOhos.GoFiles, "loopback.go") {
			problems = append(problems, "ohos 构建下 core 根包缺少 loopback.go")
		}
	}

	// 3. internal/* DAG 白名单（未登记即失败）与零 mihomo 硬边界。
	for label, pkgs := range map[string]map[string]listedPackage{"host": hostPkgs, "ohos": ohosPkgs} {
		problems = append(problems, checkPackageDAG(label, pkgs)...)
		for _, isolated := range zeroMihomoPkgs {
			pkg, exists := pkgs[isolated]
			if !exists {
				problems = append(problems, fmt.Sprintf("%s 构建缺少零 mihomo 隔离包 %s", label, isolated))
				continue
			}
			if dep, found := hasMihomoDep(pkg); found {
				problems = append(problems, fmt.Sprintf("%s 构建下 %s 严禁依赖 mihomo（命中 %s）", label, isolated, dep))
			}
		}
	}

	return problems
}

func checkSources(coreDir string) []string {
	var problems []string

	// 检查全目录文件命名：禁止 *_ohos.go（防止未来 Go 新增 GOOS=ohos 后在 GOOS=linux 构建中被隐式排除）。
	err := filepath.WalkDir(coreDir, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() {
			if entry.Name() == "testdata" {
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasSuffix(entry.Name(), "_ohos.go") {
			rel, _ := filepath.Rel(coreDir, path)
			problems = append(problems, fmt.Sprintf("core/%s 使用了 _ohos.go 后缀，请改用 //go:build ohos 搭配 *_ndk.go 或业务文件名", rel))
		}
		return nil
	})
	if err != nil {
		problems = append(problems, fmt.Sprintf("遍历 core 目录失败：%v", err))
		return problems
	}

	// 仅解析 core 根目录非测试 Go 文件，检查 init() 白名单与 //export 收口边界。
	entries, err := os.ReadDir(coreDir)
	if err != nil {
		return append(problems, fmt.Sprintf("读取 core 目录失败：%v", err))
	}
	fset := token.NewFileSet()
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		file, parseErr := parser.ParseFile(fset, filepath.Join(coreDir, name), nil, parser.ParseComments)
		if parseErr != nil {
			problems = append(problems, fmt.Sprintf("解析 core/%s 失败：%v", name, parseErr))
			continue
		}
		for _, decl := range file.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Recv != nil {
				continue
			}
			if fn.Name.Name == "init" && !allowedInitFiles[name] {
				problems = append(problems, fmt.Sprintf("core/%s 不允许新增顶层 init()，白名单仅包含路由注册与 ohos 平台钩子", name))
			}
			if fn.Doc != nil {
				for _, comment := range fn.Doc.List {
					if sym, ok := strings.CutPrefix(comment.Text, "//export "); ok {
						sym = strings.TrimSpace(sym)
						switch {
						case name == "lib.go" && strings.HasPrefix(sym, "ArkClash"):
						case name == "tailscale_network.go" && sym == "arkClashTailscaleNetworkChanged":
						default:
							problems = append(problems, fmt.Sprintf("core/%s 声明了非预期导出符号 //export %s（公开 C ABI 必须收口在 core/lib.go）", name, sym))
						}
					}
				}
			}
		}
	}
	return problems
}

func main() {
	coreDir := flag.String("core", "core", "core 模块根目录")
	modfile := flag.String("modfile", "", "临时 go.mod 路径")
	flag.Parse()

	absCore, err := filepath.Abs(*coreDir)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	var problems []string
	problems = append(problems, checkPackages(absCore, *modfile)...)
	problems = append(problems, checkSources(absCore)...)

	if len(problems) > 0 {
		for _, p := range problems {
			fmt.Fprintln(os.Stderr, p)
		}
		os.Exit(1)
	}
	fmt.Println("core 架构检查通过")
}
