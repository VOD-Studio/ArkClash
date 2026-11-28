// 检查 core/ 的 Go 架构边界：零根 .go 文件、构建标签隔离、Cgo 范围、cmd/+internal/* 5 层单向 DAG 白名单（未登记即失败）、零 mihomo 边界、全包 init() / //export / 包级变量白名单与核心锁访问边界。
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
	rootPkg           = "github.com/VOD-Studio/ArkClash/core"
	cmdClashPkg       = rootPkg + "/cmd/clash"
	cmdBackupStorePkg = rootPkg + "/cmd/backupstore"
	internalPrefix    = rootPkg + "/internal/"
	backupPkg         = internalPrefix + "backup"
	scriptPkg         = internalPrefix + "script"
	ctrlPkg           = internalPrefix + "ctrl"
	proxylinkPkg      = internalPrefix + "proxylink"
	rulesetPkg        = internalPrefix + "ruleset"
	providersPkg      = internalPrefix + "providers"
	ruletunnelPkg     = internalPrefix + "ruletunnel"
	probePkg          = internalPrefix + "probe"
	subfetchPkg       = internalPrefix + "subfetch"
	diagnosticsPkg    = internalPrefix + "diagnostics"
	geoPkg            = internalPrefix + "geo"
	configPkg         = internalPrefix + "config"
	platformPkg       = internalPrefix + "platform"
	enginePkg         = internalPrefix + "engine"
	apiPkg            = internalPrefix + "api"
	mihomoPrefix      = "github.com/metacubex/mihomo"
)

var (
	cmdClashOhosCgoFiles = []string{"lib.go"}
	platformOhosCgoFiles = []string{"hilog.go", "socket.go", "system_dns.go", "tailscale_network.go"}
	platformOhosAllFiles = []string{"hilog.go", "loopback.go", "socket.go", "system_dns.go", "tailscale_network.go"}
	hostCgoPkgs          = map[string]bool{
		cmdBackupStorePkg: true,
		scriptPkg:         true,
	}
	ohosCgoPkgs = map[string]bool{
		cmdClashPkg:       true,
		platformPkg:       true,
		cmdBackupStorePkg: true,
		scriptPkg:         true,
	}
	zeroMihomoPkgs = []string{cmdBackupStorePkg, backupPkg, scriptPkg, ctrlPkg}
	// cmd/clash 入口允许装配的 core/internal/* 包白名单（未登记即失败）。
	allowedCmdClashDeps = []string{
		apiPkg,
		configPkg,
		ctrlPkg,
		diagnosticsPkg,
		enginePkg,
		platformPkg,
		subfetchPkg,
	}
	// internal/* 5 层单向 DAG 依赖白名单（未登记即失败）：只列出每个子包允许依赖的其他 core/internal/* 包。
	allowedInternalDeps = map[string][]string{
		// L5 零核心锁基础与平台层
		backupPkg:     nil,
		scriptPkg:     nil,
		ctrlPkg:       nil,
		proxylinkPkg:  nil,
		rulesetPkg:    nil,
		ruletunnelPkg: nil,
		platformPkg:   nil,
		// L4/L3 独立子系统与零核心锁配置域
		providersPkg:   {ctrlPkg, rulesetPkg},
		probePkg:       {ctrlPkg, ruletunnelPkg},
		subfetchPkg:    {proxylinkPkg, ruletunnelPkg},
		diagnosticsPkg: {ctrlPkg},
		geoPkg:         {backupPkg, ctrlPkg, ruletunnelPkg},
		configPkg:      {backupPkg, geoPkg, proxylinkPkg, rulesetPkg, ruletunnelPkg, scriptPkg},
		// L2 核心引擎（唯一持有 core.mu / lifecycle）
		enginePkg: {backupPkg, configPkg, ctrlPkg, diagnosticsPkg, geoPkg, providersPkg, ruletunnelPkg},
		// L1 控制面路由装配
		apiPkg: {backupPkg, configPkg, ctrlPkg, diagnosticsPkg, enginePkg, geoPkg, probePkg, providersPkg, subfetchPkg},
	}
	// 全包顶层 init() 文件白名单（相对 core/ 路径，使用正斜杠）。
	allowedInitFiles = map[string]bool{
		"cmd/clash/lib.go":                       true,
		"internal/platform/loopback.go":          true,
		"internal/platform/socket.go":            true,
		"internal/platform/system_dns.go":        true,
		"internal/platform/tailscale_network.go": true,
	}
	// 全包非哨兵错误/非不可变正则/非静态地址常量的包级 var 白名单（未登记即失败）。
	allowedPackageVars = map[string]bool{
		"cmd/clash/lib.go:runtimeEngine":                        true,
		"cmd/clash/lib.go:reclaimMu":                            true,
		"cmd/clash/lib.go:lastReclaim":                          true,
		"internal/api/api.go:installOnce":                       true,
		"internal/api/api.go:installedServer":                   true,
		"internal/backup/dav.go:rfc2617Shift":                   true,
		"internal/backup/dav.go:rfc2617Table":                   true,
		"internal/backup/store.go:requiredFiles":                true,
		"internal/backup/store.go:settingFiles":                 true,
		"internal/backup/store.go:defaults":                     true,
		"internal/backup/store.go:collections":                  true,
		"internal/config/filters.go:localProxyValidation":       true,
		"internal/config/filters.go:localProxySequence":         true,
		"internal/config/scripts.go:scriptSlot":                 true,
		"internal/ctrl/commands.go:Commands":                    true,
		"internal/ctrl/events.go:Events":                        true,
		"internal/diagnostics/hub.go:diagnosticIDs":             true,
		"internal/diagnostics/stats.go:StatsInterval":           true,
		"internal/geo/download.go:DownloadTimeout":              true,
		"internal/geo/settings.go:IDs":                          true,
		"internal/platform/hilog.go:hilogOnce":                  true,
		"internal/platform/loopback.go:disableLoopBackDetector": true,
		"internal/platform/system_dns.go:systemDNSWatcher":      true,
		"internal/platform/tailscale_network.go:tailnetWatches": true,
		"internal/script/script.go:statusCodes":                 true,
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

// checkDAGTopology 校验内部包依赖白名单本身无环且不引用未登记节点。
func checkDAGTopology(deps map[string][]string) []string {
	var problems []string
	var nodes []string
	for k := range deps {
		nodes = append(nodes, k)
	}
	slices.Sort(nodes)

	const (
		unvisited = 0
		visiting  = 1
		visited   = 2
	)
	state := make(map[string]int, len(nodes))
	var dfs func(u string, stack []string)
	dfs = func(u string, stack []string) {
		state[u] = visiting
		for _, v := range deps[u] {
			if _, ok := deps[v]; !ok {
				problems = append(problems, fmt.Sprintf("DAG 白名单节点 %s 引用了未登记的包 %s", u, v))
				continue
			}
			switch state[v] {
			case visiting:
				problems = append(problems, fmt.Sprintf("DAG 白名单存在依赖环：%s -> %s", strings.Join(append(stack, u), " -> "), v))
			case unvisited:
				dfs(v, append(stack, u))
			}
		}
		state[u] = visited
	}
	for _, node := range nodes {
		if state[node] == unvisited {
			dfs(node, nil)
		}
	}
	return problems
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
			problems = append(problems, fmt.Sprintf("%s 构建下 core 根目录不允许存在 Go 包 %s（应保持零 .go 文件）", label, path))
		case path == cmdClashPkg:
			if label == "host" {
				problems = append(problems, fmt.Sprintf("宿主构建（无 ohos 标签）不应包含 %s", path))
				continue
			}
			for _, imp := range pkg.Imports {
				if strings.HasPrefix(imp, internalPrefix) && !slices.Contains(allowedCmdClashDeps, imp) {
					problems = append(problems, fmt.Sprintf("%s 构建下 %s 不允许依赖 %s（允许列表：%v）", label, path, imp, allowedCmdClashDeps))
				}
			}
		case path == cmdBackupStorePkg:
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

	if label == "ohos" {
		if _, ok := pkgs[cmdClashPkg]; !ok {
			problems = append(problems, fmt.Sprintf("%s 构建缺少入口包 %s", label, cmdClashPkg))
		}
	}
	if _, ok := pkgs[cmdBackupStorePkg]; !ok {
		problems = append(problems, fmt.Sprintf("%s 构建缺少入口包 %s", label, cmdBackupStorePkg))
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
	problems = append(problems, checkDAGTopology(allowedInternalDeps)...)

	// 1. 宿主标签（不带 ohos）：无根包、无 cmd/clash，internal/platform 不得有 Cgo，且只能由 cmd/backupstore 与 internal/script 使用 Cgo。
	hostPkgs, err := goList(coreDir, modfile, "with_gvisor", "CGO_ENABLED=1")
	if err != nil {
		return []string{err.Error()}
	}
	if platHost, ok := hostPkgs[platformPkg]; !ok {
		problems = append(problems, "宿主 go list 缺少平台包 "+platformPkg)
	} else {
		if len(platHost.CgoFiles) > 0 {
			problems = append(problems, fmt.Sprintf("宿主构建下 %s 不允许出现 CgoFiles：%v", platformPkg, platHost.CgoFiles))
		}
		included := append(slices.Clone(platHost.GoFiles), platHost.CgoFiles...)
		for _, forbidden := range platformOhosAllFiles {
			if slices.Contains(included, forbidden) {
				problems = append(problems, fmt.Sprintf("宿主构建（无 ohos 标签）下 %s 意外包含了平台文件：%s", platformPkg, forbidden))
			}
		}
	}
	for path, pkg := range hostPkgs {
		if len(pkg.CgoFiles) > 0 && !hostCgoPkgs[path] {
			problems = append(problems, fmt.Sprintf("宿主构建下非白名单包 %s 存在 CgoFiles：%v", path, pkg.CgoFiles))
		}
	}

	// 2. OHOS 目标标签（with_gvisor,ohos）：正向核对 cmd/clash 与 internal/platform 全部 6 个平台/ABI 文件被包含，避免标签拼错静默跳过。
	ohosPkgs, err := goList(coreDir, modfile, "with_gvisor,ohos", "CGO_ENABLED=1", "GOOS=linux", "GOARCH=arm64")
	if err != nil {
		return append(problems, err.Error())
	}
	if clashOhos, ok := ohosPkgs[cmdClashPkg]; ok {
		gotCgo := slices.Clone(clashOhos.CgoFiles)
		slices.Sort(gotCgo)
		wantCgo := slices.Clone(cmdClashOhosCgoFiles)
		slices.Sort(wantCgo)
		if !slices.Equal(gotCgo, wantCgo) || len(clashOhos.GoFiles) > 0 {
			problems = append(problems, fmt.Sprintf("ohos 构建下 %s GoFiles=%v CgoFiles=%v，预期 GoFiles=[] CgoFiles=%v", cmdClashPkg, clashOhos.GoFiles, gotCgo, wantCgo))
		}
	}
	if platOhos, ok := ohosPkgs[platformPkg]; !ok {
		problems = append(problems, "ohos go list 缺少平台包 "+platformPkg)
	} else {
		gotCgo := slices.Clone(platOhos.CgoFiles)
		slices.Sort(gotCgo)
		wantCgo := slices.Clone(platformOhosCgoFiles)
		slices.Sort(wantCgo)
		if !slices.Equal(gotCgo, wantCgo) {
			problems = append(problems, fmt.Sprintf("ohos 构建下 %s CgoFiles=%v，预期=%v", platformPkg, gotCgo, wantCgo))
		}
		if !slices.Contains(platOhos.GoFiles, "loopback.go") {
			problems = append(problems, fmt.Sprintf("ohos 构建下 %s 缺少 loopback.go", platformPkg))
		}
		if !slices.Contains(platOhos.GoFiles, "tailscale_watch.go") {
			problems = append(problems, fmt.Sprintf("ohos 构建下 %s 缺少 tailscale_watch.go", platformPkg))
		}
	}
	for path, pkg := range ohosPkgs {
		if len(pkg.CgoFiles) > 0 && !ohosCgoPkgs[path] {
			problems = append(problems, fmt.Sprintf("ohos 构建下非白名单包 %s 存在 CgoFiles：%v", path, pkg.CgoFiles))
		}
	}

	// 3. cmd/ 与 internal/* 5 层单向 DAG 白名单（未登记即失败）与零 mihomo 硬边界。
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

func isImmutableVar(name string, init ast.Expr) bool {
	if init == nil {
		return false
	}
	if strings.HasPrefix(name, "err") || strings.HasPrefix(name, "Err") {
		if call, ok := init.(*ast.CallExpr); ok {
			if sel, ok := call.Fun.(*ast.SelectorExpr); ok {
				if pkg, ok := sel.X.(*ast.Ident); ok && pkg.Name == "errors" && sel.Sel.Name == "New" {
					return true
				}
			}
		}
	}
	if call, ok := init.(*ast.CallExpr); ok {
		if sel, ok := call.Fun.(*ast.SelectorExpr); ok {
			// regexp.MustCompile(...)
			if pkg, ok := sel.X.(*ast.Ident); ok && pkg.Name == "regexp" && sel.Sel.Name == "MustCompile" {
				return true
			}
			// netip.MustParseAddr(...)
			if pkg, ok := sel.X.(*ast.Ident); ok && pkg.Name == "netip" && strings.HasPrefix(sel.Sel.Name, "MustParse") {
				return true
			}
			// netip.MustParseAddrPort(...).Addr()
			if inner, ok := sel.X.(*ast.CallExpr); ok && sel.Sel.Name == "Addr" {
				if innerSel, ok := inner.Fun.(*ast.SelectorExpr); ok {
					if pkg, ok := innerSel.X.(*ast.Ident); ok && pkg.Name == "netip" && strings.HasPrefix(innerSel.Sel.Name, "MustParse") {
						return true
					}
				}
			}
		}
	}
	return false
}

func isEngineType(expr ast.Expr) bool {
	if star, ok := expr.(*ast.StarExpr); ok {
		expr = star.X
	}
	ident, ok := expr.(*ast.Ident)
	return ok && ident.Name == "Engine"
}

func engineVarNames(fn *ast.FuncDecl) map[string]bool {
	names := make(map[string]bool)
	collect := func(fl *ast.FieldList) {
		if fl == nil {
			return
		}
		for _, field := range fl.List {
			if !isEngineType(field.Type) {
				continue
			}
			for _, ident := range field.Names {
				if ident.Name != "" && ident.Name != "_" {
					names[ident.Name] = true
				}
			}
		}
	}
	collect(fn.Recv)
	if fn.Type != nil {
		collect(fn.Type.Params)
	}
	return names
}

func checkSources(coreDir string) []string {
	return scanSources(coreDir, true)
}

func scanSources(coreDir string, checkStale bool) []string {
	var problems []string
	seenVars := make(map[string]bool)
	seenInits := make(map[string]bool)
	fset := token.NewFileSet()

	// 遍历 core/ 全目录 Go 文件：
	// - core/ 根目录严禁留存任何 .go 文件（含测试文件）；
	// - 禁止 *_ohos.go 命名；
	// - 除 cmd/clash/lib.go 与 internal/platform/*.go 外禁止出现 //go:build ohos；
	// - 全包校验 init() 白名单、//export 导出位置与包级 var 白名单；
	// - internal/engine 校验核心锁（mu/lifecycle）仅限 internal/engine/engine.go 访问。
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
		relPath, _ := filepath.Rel(coreDir, path)
		rel := filepath.ToSlash(relPath)
		name := entry.Name()
		if !strings.Contains(rel, "/") && strings.HasSuffix(name, ".go") {
			problems = append(problems, fmt.Sprintf("core/%s 不允许留在模块根目录（core/ 根目录须保持零 .go 文件，入口位于 cmd/、实现位于 internal/）", rel))
		}
		if strings.HasSuffix(name, "_ohos.go") {
			problems = append(problems, fmt.Sprintf("core/%s 使用了 _ohos.go 后缀，请改用 //go:build ohos 搭配 *_ndk.go 或业务文件名", rel))
		}
		if !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			return nil
		}

		file, parseErr := parser.ParseFile(fset, path, nil, parser.ParseComments)
		if parseErr != nil {
			problems = append(problems, fmt.Sprintf("解析 core/%s 失败：%v", rel, parseErr))
			return nil
		}

		// 检查 //go:build ohos 只允许出现在 cmd/clash/lib.go 和 internal/platform/*.go。
		for _, cg := range file.Comments {
			if cg.Pos() >= file.Package {
				break
			}
			for _, c := range cg.List {
				if strings.HasPrefix(c.Text, "//go:build ") && strings.Contains(c.Text, "ohos") {
					if rel != "cmd/clash/lib.go" && !strings.HasPrefix(rel, "internal/platform/") {
						problems = append(problems, fmt.Sprintf("core/%s 不允许使用 ohos 构建标签（仅允许 cmd/clash/lib.go 与 internal/platform）", rel))
					}
				}
			}
		}

		isEngine := strings.HasPrefix(rel, "internal/engine/")
		for _, decl := range file.Decls {
			switch d := decl.(type) {
			case *ast.GenDecl:
				if d.Tok != token.VAR {
					continue
				}
				for _, spec := range d.Specs {
					vs, ok := spec.(*ast.ValueSpec)
					if !ok {
						continue
					}
					for i, ident := range vs.Names {
						if ident.Name == "_" {
							continue
						}
						var initExpr ast.Expr
						if i < len(vs.Values) {
							initExpr = vs.Values[i]
						}
						if isImmutableVar(ident.Name, initExpr) {
							continue
						}
						key := rel + ":" + ident.Name
						seenVars[key] = true
						if !allowedPackageVars[key] {
							problems = append(problems, fmt.Sprintf("core/%s 声明了未登记的包级变量 %s（请归入 Engine 或子系统 Hub，确需保留须在 check-core-arch 白名单登记）", rel, ident.Name))
						}
					}
				}
			case *ast.FuncDecl:
				if d.Recv == nil {
					if d.Name.Name == "init" {
						seenInits[rel] = true
						if !allowedInitFiles[rel] {
							problems = append(problems, fmt.Sprintf("core/%s 不允许新增顶层 init()，白名单仅包含入口装配与 ohos 平台钩子", rel))
						}
					}
					if d.Doc != nil {
						for _, comment := range d.Doc.List {
							if sym, ok := strings.CutPrefix(comment.Text, "//export "); ok {
								sym = strings.TrimSpace(sym)
								switch {
								case rel == "cmd/clash/lib.go" && strings.HasPrefix(sym, "ArkClash"):
								case rel == "cmd/backupstore/main.go" && strings.HasPrefix(sym, "ArkStore"):
								case rel == "internal/platform/tailscale_network.go" && sym == "arkClashTailscaleNetworkChanged":
								default:
									problems = append(problems, fmt.Sprintf("core/%s 声明了非预期导出符号 //export %s（公开 C ABI 必须收口在 cmd/ 入口或平台回调）", rel, sym))
								}
							}
						}
					}
				}
				if isEngine && rel != "internal/engine/engine.go" && d.Body != nil {
					engineVars := engineVarNames(d)
					if len(engineVars) > 0 {
						ast.Inspect(d.Body, func(n ast.Node) bool {
							sel, ok := n.(*ast.SelectorExpr)
							if !ok || (sel.Sel.Name != "mu" && sel.Sel.Name != "lifecycle") {
								return true
							}
							x, ok := sel.X.(*ast.Ident)
							if !ok {
								return true
							}
							if engineVars[x.Name] {
								pos := fset.Position(sel.Pos())
								problems = append(problems, fmt.Sprintf("core/%s:%d 禁止在 internal/engine/engine.go 之外直接访问核心锁 %s.%s（请经 engine.go 事务入口进入）", rel, pos.Line, x.Name, sel.Sel.Name))
							}
							return true
						})
					}
				}
			}
		}
		return nil
	})
	if err != nil {
		problems = append(problems, fmt.Sprintf("遍历 core 目录失败：%v", err))
		return problems
	}

	if checkStale {
		var allowedVarKeys []string
		for key := range allowedPackageVars {
			allowedVarKeys = append(allowedVarKeys, key)
		}
		slices.Sort(allowedVarKeys)
		for _, key := range allowedVarKeys {
			if !seenVars[key] {
				problems = append(problems, fmt.Sprintf("check-core-arch 的 allowedPackageVars 存在陈旧条目 %s，请同步清理", key))
			}
		}

		var allowedInitKeys []string
		for key := range allowedInitFiles {
			allowedInitKeys = append(allowedInitKeys, key)
		}
		slices.Sort(allowedInitKeys)
		for _, key := range allowedInitKeys {
			if !seenInits[key] {
				problems = append(problems, fmt.Sprintf("check-core-arch 的 allowedInitFiles 存在陈旧条目 %s，请同步清理", key))
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
