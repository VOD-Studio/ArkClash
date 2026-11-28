// 构建时提取 mihomo 源码中的日志字面量。运行时只返回预先脱敏的正文，动态 format 无法带出节点或凭据。
package main

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

var formatVerb = regexp.MustCompile(`%(?:\[[0-9]+\])?[-+#0 .0-9]*[a-zA-Z%]`)
var templateURL = regexp.MustCompile(`[A-Za-z][A-Za-z0-9+.-]*://[^\s]+`)

func collectTemplates(path string, templates map[string]string) error {
	file, err := parser.ParseFile(token.NewFileSet(), path, nil, parser.SkipObjectResolution)
	if err != nil {
		return err
	}
	for _, imp := range file.Imports {
		if imp.Path.Value != `"github.com/metacubex/mihomo/log"` {
			continue
		}
		name := "log"
		if imp.Name != nil {
			name = imp.Name.Name
		}
		ast.Inspect(file, func(node ast.Node) bool {
			call, ok := node.(*ast.CallExpr)
			if !ok || len(call.Args) == 0 {
				return true
			}
			sel, ok := call.Fun.(*ast.SelectorExpr)
			if !ok {
				return true
			}
			pkg, ok := sel.X.(*ast.Ident)
			if !ok || pkg.Name != name {
				return true
			}
			switch sel.Sel.Name {
			case "Debugln", "Infoln", "Warnln", "Errorln":
				lit, ok := call.Args[0].(*ast.BasicLit)
				if ok && lit.Kind == token.STRING {
					text, _ := strconv.Unquote(lit.Value)
					safe := templateURL.ReplaceAllString(formatVerb.ReplaceAllString(text, "…"), "…")
					safe = strings.Join(strings.Fields(safe), " ")
					if safe != "" && safe != "…" && len(safe) <= 256 {
						templates[text] = safe
					}
				}
			}
			return true
		})
	}
	return nil
}

func main() {
	root := os.Args[1]
	templates := make(map[string]string)
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil || entry.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return err
		}
		return collectTemplates(path, templates)
	})
	if err != nil {
		log.Fatal(err)
	}
	var keys []string
	for key := range templates {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	var source strings.Builder
	source.WriteString("package log\n\nfunc ArkClashStaticLogMessage(format string) string {\n\tswitch format {\n")
	for _, key := range keys {
		fmt.Fprintf(&source, "\tcase %q:\n\t\treturn %q\n", key, templates[key])
	}
	source.WriteString("\t}\n\treturn \"\"\n}\n")
	if err := os.WriteFile(filepath.Join(root, "log", "arkclash_log_templates.go"), []byte(source.String()), 0644); err != nil {
		log.Fatal(err)
	}
}
