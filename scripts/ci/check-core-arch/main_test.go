package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeFixtureFile(t *testing.T, root, rel, content string) {
	t.Helper()
	full := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func requireProblem(t *testing.T, problems []string, wantSubstr string) {
	t.Helper()
	for _, p := range problems {
		if strings.Contains(p, wantSubstr) {
			return
		}
	}
	t.Fatalf("expected problem containing %q, got %v", wantSubstr, problems)
}

func validPackageSet(label string) map[string]listedPackage {
	pkgs := map[string]listedPackage{
		cmdBackupStorePkg: {ImportPath: cmdBackupStorePkg, Imports: []string{backupPkg}},
	}
	if label == "ohos" {
		pkgs[cmdClashPkg] = listedPackage{ImportPath: cmdClashPkg, Imports: allowedCmdClashDeps}
	}
	for pkg, deps := range allowedInternalDeps {
		pkgs[pkg] = listedPackage{ImportPath: pkg, Imports: deps}
	}
	return pkgs
}

func TestCheckDAGTopologyValidAndCycleRejected(t *testing.T) {
	if problems := checkDAGTopology(allowedInternalDeps); len(problems) > 0 {
		t.Fatalf("production allowedInternalDeps should be acyclic, got %v", problems)
	}
	cyclic := map[string][]string{
		"a": {"b"},
		"b": {"c"},
		"c": {"a"},
	}
	requireProblem(t, checkDAGTopology(cyclic), "存在依赖环")

	dangling := map[string][]string{
		"a": {"missing"},
	}
	requireProblem(t, checkDAGTopology(dangling), "引用了未登记的包")
}

func TestCheckPackageDAGRejectsViolations(t *testing.T) {
	if problems := checkPackageDAG("host", validPackageSet("host")); len(problems) > 0 {
		t.Fatalf("valid host set failed: %v", problems)
	}
	if problems := checkPackageDAG("ohos", validPackageSet("ohos")); len(problems) > 0 {
		t.Fatalf("valid ohos set failed: %v", problems)
	}

	// 1. 根目录不允许残留包。
	withRoot := validPackageSet("host")
	withRoot[rootPkg] = listedPackage{ImportPath: rootPkg}
	requireProblem(t, checkPackageDAG("host", withRoot), "根目录不允许存在 Go 包")

	// 2. 宿主构建不允许包含 cmd/clash。
	hostWithClash := validPackageSet("host")
	hostWithClash[cmdClashPkg] = listedPackage{ImportPath: cmdClashPkg}
	requireProblem(t, checkPackageDAG("host", hostWithClash), "不应包含")

	// 3. cmd/clash 禁止越级依赖未登记的 internal 包（例如 geo）。
	clashExtra := validPackageSet("ohos")
	clashExtra[cmdClashPkg] = listedPackage{ImportPath: cmdClashPkg, Imports: []string{geoPkg}}
	requireProblem(t, checkPackageDAG("ohos", clashExtra), "不允许依赖 "+geoPkg)

	// 4. cmd/backupstore 禁止依赖 internal/backup 之外的包。
	storeBad := validPackageSet("host")
	storeBad[cmdBackupStorePkg] = listedPackage{ImportPath: cmdBackupStorePkg, Imports: []string{backupPkg, enginePkg}}
	requireProblem(t, checkPackageDAG("host", storeBad), "只允许依赖 "+backupPkg)

	// 5. 未登记的 internal/* 包必须失败。
	unknownInternal := validPackageSet("host")
	unknownInternal[internalPrefix+"rogue"] = listedPackage{ImportPath: internalPrefix + "rogue"}
	requireProblem(t, checkPackageDAG("host", unknownInternal), "未登记的内部包")

	// 6. 反向或跨层边必须失败（engine -> api、platform -> diagnostics、config -> engine）。
	revEngine := validPackageSet("host")
	revEngine[enginePkg] = listedPackage{ImportPath: enginePkg, Imports: []string{apiPkg}}
	requireProblem(t, checkPackageDAG("host", revEngine), enginePkg+" 不允许依赖 "+apiPkg)

	revPlatform := validPackageSet("host")
	revPlatform[platformPkg] = listedPackage{ImportPath: platformPkg, Imports: []string{diagnosticsPkg}}
	requireProblem(t, checkPackageDAG("host", revPlatform), platformPkg+" 不允许依赖 "+diagnosticsPkg)

	revConfig := validPackageSet("host")
	revConfig[configPkg] = listedPackage{ImportPath: configPkg, Imports: []string{enginePkg}}
	requireProblem(t, checkPackageDAG("host", revConfig), configPkg+" 不允许依赖 "+enginePkg)

	// 7. 缺少已登记的 internal 包必须失败。
	missingPkg := validPackageSet("host")
	delete(missingPkg, probePkg)
	requireProblem(t, checkPackageDAG("host", missingPkg), "缺少已登记的内部包 "+probePkg)
}

func TestHasMihomoDep(t *testing.T) {
	if _, ok := hasMihomoDep(listedPackage{Imports: []string{"fmt"}, Deps: []string{"os"}}); ok {
		t.Fatal("stdlib package should not match mihomo")
	}
	if dep, ok := hasMihomoDep(listedPackage{Imports: []string{mihomoPrefix + "/log"}}); !ok || dep != mihomoPrefix+"/log" {
		t.Fatalf("direct mihomo import not detected: dep=%q ok=%v", dep, ok)
	}
	if dep, ok := hasMihomoDep(listedPackage{Deps: []string{mihomoPrefix}}); !ok || dep != mihomoPrefix {
		t.Fatalf("transitive mihomo dep not detected: dep=%q ok=%v", dep, ok)
	}
}

func TestScanSourcesRejectsViolations(t *testing.T) {
	cases := []struct {
		name   string
		rel    string
		source string
		want   string
	}{
		{
			name:   "root go file forbidden",
			rel:    "stray.go",
			source: "package core\n",
			want:   "不允许留在模块根目录",
		},
		{
			name:   "root test file forbidden",
			rel:    "stray_test.go",
			source: "package core\n",
			want:   "不允许留在模块根目录",
		},
		{
			name:   "ohos filename suffix forbidden",
			rel:    "internal/platform/net_ohos.go",
			source: "package platform\n",
			want:   "使用了 _ohos.go 后缀",
		},
		{
			name:   "ohos build tag outside whitelist",
			rel:    "internal/engine/bad_tag.go",
			source: "//go:build ohos\n\npackage engine\n",
			want:   "不允许使用 ohos 构建标签",
		},
		{
			name:   "unauthorized init",
			rel:    "internal/api/extra.go",
			source: "package api\n\nfunc init() {}\n",
			want:   "不允许新增顶层 init()",
		},
		{
			name:   "unauthorized export",
			rel:    "internal/engine/export.go",
			source: "package engine\n\n//export ArkClashRogue\nfunc ArkClashRogue() {}\n",
			want:   "非预期导出符号 //export ArkClashRogue",
		},
		{
			name:   "direct mu access outside engine.go",
			rel:    "internal/engine/rogue.go",
			source: "package engine\n\ntype Engine struct{ mu int }\nfunc (e *Engine) bad() { _ = e.mu }\n",
			want:   "禁止在 internal/engine/engine.go 之外直接访问核心锁 e.mu",
		},
		{
			name:   "direct lifecycle access via param outside engine.go",
			rel:    "internal/engine/rogue_param.go",
			source: "package engine\n\ntype Engine struct{ lifecycle int }\nfunc helper(eng *Engine) { _ = eng.lifecycle }\n",
			want:   "禁止在 internal/engine/engine.go 之外直接访问核心锁 eng.lifecycle",
		},
		{
			name:   "unregistered package var in internal package",
			rel:    "internal/geo/leak.go",
			source: "package geo\n\nvar sneakyState int\n",
			want:   "声明了未登记的包级变量 sneakyState",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			writeFixtureFile(t, dir, tc.rel, tc.source)
			problems := scanSources(dir, false)
			requireProblem(t, problems, tc.want)
		})
	}
}

func TestScanSourcesAllowsImmutableVarsAndDetectsStaleWhitelist(t *testing.T) {
	dir := t.TempDir()
	writeFixtureFile(t, dir, "internal/engine/clean.go", `package engine

import (
	"errors"
	"net/netip"
	"regexp"
)

var (
	errSample  = errors.New("sample")
	ErrExport  = errors.New("export")
	pattern    = regexp.MustCompile("^ok$")
	addr       = netip.MustParseAddr("127.0.0.1")
	addrPort   = netip.MustParseAddrPort("127.0.0.1:53").Addr()
)
`)
	if problems := scanSources(dir, false); len(problems) > 0 {
		t.Fatalf("immutable vars should be allowed, got %v", problems)
	}
	staleProblems := scanSources(dir, true)
	requireProblem(t, staleProblems, "allowedPackageVars 存在陈旧条目")
	requireProblem(t, staleProblems, "allowedInitFiles 存在陈旧条目")
}
