// Package ruleset 提供规则集标识约定、格式嗅探、MRS 校验与编译能力。
package ruleset

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"net/netip"
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/klauspost/compress/zstd"
	"github.com/metacubex/mihomo/component/trie"
	P "github.com/metacubex/mihomo/constant/provider"
	R "github.com/metacubex/mihomo/rules"
	"github.com/metacubex/mihomo/rules/common"
	RP "github.com/metacubex/mihomo/rules/provider"
	"go.yaml.in/yaml/v3"
)

const InputLimit = 8 << 20
const OutputLimit = 16 << 20
const LineLimit = 300000

const managedPrefix = "__arkclash_ruleset_"

var ErrContent = errors.New("rule_set_content")

var (
	idPattern        = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,79}$`)
	nonPortableChild = regexp.MustCompile(`(?i)\(\s*(RULE-SET|SUB-RULE|UID|PROCESS-[A-Z-]+)\s*,`)
	yamlHeader       = regexp.MustCompile(`(?m)^[\t ]*(payload|rules)[\t ]*:`)
	domainPattern    = regexp.MustCompile(`^[\pL\pM\pN_.+*\-]+$`)
)

func ValidID(id string) bool { return idPattern.MatchString(id) }

func ManagedName(id string) string { return managedPrefix + id }

func IsManagedName(name string) bool { return strings.HasPrefix(name, managedPrefix) }

// HasNonPortableChild 检测复合规则或 classical 规则集内是否包含不可移植的子规则类型。
func HasNonPortableChild(line string) bool { return nonPortableChild.MatchString(line) }

func DetectFormat(data []byte) string {
	if bytes.HasPrefix(data, []byte{0x28, 0xb5, 0x2f, 0xfd}) {
		return "mrs"
	}
	trimmed := bytes.TrimSpace(bytes.TrimPrefix(data, []byte("\xef\xbb\xbf")))
	if bytes.HasPrefix(trimmed, []byte("{")) || yamlHeader.Match(trimmed) {
		return "yaml"
	}
	return "text"
}

type ruleSetBuffer struct {
	bytes.Buffer
	failed bool
}

func (b *ruleSetBuffer) Write(data []byte) (int, error) {
	if len(data) > OutputLimit-b.Len() {
		b.failed = true
		return 0, ErrContent
	}
	return b.Buffer.Write(data)
}

func Compile(data []byte, behavior, format string) (result []byte, count int, err error) {
	defer func() {
		if recover() != nil {
			result, count, err = nil, 0, ErrContent
		}
	}()
	if len(data) == 0 || len(data) > InputLimit {
		return nil, 0, ErrContent
	}
	kind, err := P.ParseBehavior(behavior)
	if err != nil {
		return nil, 0, ErrContent
	}
	if format == "mrs" {
		var expanded ruleSetBuffer
		if !ValidateMRS(data, kind) || RP.ConvertToMrs(data, kind, P.MrsRule, &expanded) != nil || expanded.failed {
			return nil, 0, ErrContent
		}
		data = expanded.Bytes()
		format = "text"
	}
	if !utf8.Valid(data) || bytes.IndexByte(data, 0) >= 0 {
		return nil, 0, ErrContent
	}
	data = bytes.TrimPrefix(data, []byte("\xef\xbb\xbf"))
	var lines []string
	switch format {
	case "yaml":
		var root yaml.Node
		decoder := yaml.NewDecoder(bytes.NewReader(data))
		if decoder.Decode(&root) != nil || decoder.Decode(new(yaml.Node)) != io.EOF ||
			len(root.Content) != 1 || root.Content[0].Kind != yaml.MappingNode {
			return nil, 0, ErrContent
		}
		fields := root.Content[0].Content
		for i := 0; i < len(fields); i += 2 {
			if fields[i].Value != "payload" && fields[i].Value != "rules" {
				continue
			}
			list := fields[i+1]
			if lines != nil || list.Kind != yaml.SequenceNode || len(list.Content) > LineLimit {
				return nil, 0, ErrContent
			}
			lines = make([]string, 0, len(list.Content))
			for _, node := range list.Content {
				if node.Kind != yaml.ScalarNode {
					return nil, 0, ErrContent
				}
				lines = append(lines, node.Value)
			}
		}
	case "text":
		var line string
		for line = range strings.SplitSeq(string(data), "\n") {
			line = strings.TrimSpace(line)
			if line != "" && !strings.HasPrefix(line, "#") && !strings.HasPrefix(line, "//") {
				if len(lines) >= LineLimit {
					return nil, 0, ErrContent
				}
				lines = append(lines, line)
			}
		}
	default:
		return nil, 0, ErrContent
	}
	if len(lines) == 0 {
		return nil, 0, ErrContent
	}
	var output ruleSetBuffer
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || len(line) > 2048 || strings.ContainsAny(line, "\x00\r\n") ||
			strings.HasPrefix(line, "#") || strings.HasPrefix(line, "//") {
			return nil, 0, ErrContent
		}
		switch kind {
		case P.Domain:
			if !domainPattern.MatchString(line) {
				return nil, 0, ErrContent
			}
			if _, err := trie.ValidAndSplitDomain(line); err != nil {
				return nil, 0, ErrContent
			}
		case P.IPCIDR:
			prefix, err := netip.ParsePrefix(line)
			if err != nil {
				return nil, 0, ErrContent
			}
			line = prefix.Masked().String()
		case P.Classical:
			ruleType, payload, target, params := common.ParseRulePayload(line, false)
			switch ruleType {
			case "MATCH", "RULE-SET", "SUB-RULE", "UID":
				return nil, 0, ErrContent
			}
			if HasNonPortableChild(line) || strings.HasPrefix(ruleType, "PROCESS-") {
				return nil, 0, ErrContent
			}
			if _, err := R.ParseRule(ruleType, payload, target, params, nil); err != nil {
				return nil, 0, ErrContent
			}
		}
		if _, err := output.Write([]byte(line + "\n")); err != nil {
			return nil, 0, ErrContent
		}
	}
	return output.Bytes(), len(lines), nil
}

// mihomo 的 MRS 读取器会按文件声明的长度分配。先限制解压量，再核对每个数组和树深。
func ValidateMRS(data []byte, kind P.RuleBehavior) bool {
	if kind != P.Domain && kind != P.IPCIDR {
		return false
	}
	decoder, err := zstd.NewReader(bytes.NewReader(data), zstd.WithDecoderMaxMemory(32<<20), zstd.WithDecoderConcurrency(1))
	if err != nil {
		return false
	}
	defer decoder.Close()
	plain, err := io.ReadAll(io.LimitReader(decoder, OutputLimit+1))
	if err != nil || len(plain) < 22 || len(plain) > OutputLimit || !bytes.Equal(plain[:4], RP.MrsMagicBytes[:]) ||
		plain[4] != kind.Byte() {
		return false
	}
	count := binary.BigEndian.Uint64(plain[5:13])
	extra := binary.BigEndian.Uint64(plain[13:21])
	if count == 0 || count > LineLimit || extra > uint64(len(plain)-22) || plain[21+extra] != 1 {
		return false
	}
	rest := plain[22+extra:]
	readArray := func(size uint64) []byte {
		if len(rest) < 8 {
			return nil
		}
		n := binary.BigEndian.Uint64(rest[:8])
		if n == 0 || n > uint64(len(rest)-8)/size {
			return nil
		}
		field := rest[8 : 8+n*size]
		rest = rest[8+n*size:]
		return field
	}
	if kind == P.IPCIDR {
		ranges := readArray(32)
		if ranges == nil || len(rest) != 0 {
			return false
		}
		for i := 0; i < len(ranges); i += 32 {
			from := netip.AddrFrom16([16]byte(ranges[i : i+16])).Unmap()
			to := netip.AddrFrom16([16]byte(ranges[i+16 : i+32])).Unmap()
			if from.BitLen() != to.BitLen() || from.Compare(to) > 0 {
				return false
			}
		}
		return true
	}
	leaves, bitmap, labels := readArray(8), readArray(8), readArray(1)
	nodes := len(labels) + 1
	bits := nodes + len(labels)
	if len(rest) != 0 || labels == nil || len(leaves) != (nodes+63)/64*8 || len(bitmap) != (bits+63)/64*8 {
		return false
	}
	// LOUDS 按层记录每个节点的子边，零是子边，一是节点终止符。
	seen, edges, levelEnd, depth := 0, 0, 1, 0
	word := uint64(0)
	for i := 0; i < bits; i++ {
		if i%64 == 0 {
			word = binary.BigEndian.Uint64(bitmap[i/64*8:])
		}
		if word&(uint64(1)<<uint(i%64)) == 0 {
			edges++
			continue
		}
		seen++
		if seen > nodes || edges < seen-1 || edges > len(labels) {
			return false
		}
		if seen == levelEnd && seen < nodes {
			if edges+1 <= seen || depth >= 2048 {
				return false
			}
			levelEnd = edges + 1
			depth++
		}
	}
	return seen == nodes && edges == len(labels) && bits > 0 &&
		word&(uint64(1)<<uint((bits-1)%64)) != 0
}
