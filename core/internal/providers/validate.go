package providers

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"

	"github.com/VOD-Studio/ArkClash/core/internal/ruleset"
	"github.com/metacubex/mihomo/component/trie"
	P "github.com/metacubex/mihomo/constant/provider"
	R "github.com/metacubex/mihomo/rules"
	"github.com/metacubex/mihomo/rules/common"
	"go.yaml.in/yaml/v3"
)

const (
	candidateLimit = 16 << 20
	maxLines       = 300000
)

func sanitizeUpdateError(err error) string {
	if err == nil {
		return ""
	}
	if errors.Is(err, context.DeadlineExceeded) || os.IsTimeout(err) {
		return errTimeout.Error()
	}
	return errUpdateFailed.Error()
}

func checkCandidatePath(homeDir, candidate string) error {
	if candidate == "" {
		return errInvalidRequest
	}
	clean := filepath.Clean(candidate)
	dir := filepath.Dir(clean)
	if dir != filepath.Join(homeDir, "profile-work") && dir != filepath.Join(homeDir, "profiles") {
		return errInvalidRequest
	}
	return nil
}

func readCandidate(homeDir, candidate string) ([]byte, error) {
	if err := checkCandidatePath(homeDir, candidate); err != nil {
		return nil, err
	}
	info, err := os.Lstat(candidate)
	if err != nil {
		return nil, errIO
	}
	if !info.Mode().IsRegular() {
		return nil, errInvalidRequest
	}
	if info.Size() <= 0 || info.Size() > candidateLimit {
		return nil, errInvalidContent
	}
	file, err := os.Open(candidate)
	if err != nil {
		return nil, errIO
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, candidateLimit+1))
	if err != nil {
		return nil, errIO
	}
	if len(data) == 0 || len(data) > candidateLimit {
		return nil, errInvalidContent
	}
	return data, nil
}

// 严格按当前 rule-provider 的 behavior 与 format 校验候选内容，防止 mihomo 静默跳过坏行导致规则被清空。
func validateRuleCandidate(data []byte, behavior P.RuleBehavior, format P.RuleFormat) error {
	if len(data) == 0 || len(data) > candidateLimit {
		return errInvalidContent
	}
	if format == P.MrsRule {
		if len(data) > ruleset.InputLimit || !ruleset.ValidateMRS(data, behavior) {
			return errInvalidContent
		}
		return nil
	}
	if !utf8.Valid(data) || bytes.IndexByte(data, 0) >= 0 {
		return errInvalidContent
	}
	trimmed := bytes.TrimPrefix(data, []byte("\xef\xbb\xbf"))
	var lines []string
	switch format {
	case P.YamlRule:
		var root yaml.Node
		decoder := yaml.NewDecoder(bytes.NewReader(trimmed))
		if decoder.Decode(&root) != nil || decoder.Decode(new(yaml.Node)) != io.EOF ||
			len(root.Content) != 1 || root.Content[0].Kind != yaml.MappingNode {
			return errInvalidContent
		}
		fields := root.Content[0].Content
		for i := 0; i < len(fields); i += 2 {
			if fields[i].Value != "payload" && fields[i].Value != "rules" {
				continue
			}
			list := fields[i+1]
			if lines != nil || list.Kind != yaml.SequenceNode || len(list.Content) > maxLines {
				return errInvalidContent
			}
			lines = make([]string, 0, len(list.Content))
			for _, node := range list.Content {
				if node.Kind != yaml.ScalarNode {
					return errInvalidContent
				}
				lines = append(lines, node.Value)
			}
		}
	case P.TextRule:
		for line := range strings.SplitSeq(string(trimmed), "\n") {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, "//") {
				continue
			}
			if len(lines) >= maxLines {
				return errInvalidContent
			}
			lines = append(lines, line)
		}
	default:
		return errInvalidContent
	}
	if len(lines) == 0 {
		return errInvalidContent
	}
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || len(line) > 2048 || strings.ContainsAny(line, "\x00\r\n") ||
			strings.HasPrefix(line, "#") || strings.HasPrefix(line, "//") {
			return errInvalidContent
		}
		switch behavior {
		case P.Domain:
			if strings.ContainsRune(line, '/') {
				return errInvalidContent
			}
			if _, err := trie.ValidAndSplitDomain(line); err != nil {
				return errInvalidContent
			}
		case P.IPCIDR:
			if _, err := netip.ParsePrefix(line); err != nil {
				return errInvalidContent
			}
		case P.Classical:
			ruleType, payload, target, params := common.ParseRulePayload(line, false)
			switch ruleType {
			case "MATCH", "RULE-SET", "SUB-RULE":
				return errInvalidContent
			}
			if _, err := R.ParseRule(ruleType, payload, target, params, nil); err != nil {
				return errInvalidContent
			}
		default:
			return errInvalidContent
		}
	}
	return nil
}
