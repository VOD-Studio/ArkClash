package config

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"

	"github.com/VOD-Studio/ArkClash/core/internal/geo"
	"github.com/VOD-Studio/ArkClash/core/internal/ruleset"
	"github.com/VOD-Studio/ArkClash/core/internal/script"
	"github.com/metacubex/mihomo/component/process"
	mihomoConfig "github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
	"go.yaml.in/yaml/v3"
)

// 预览 YAML 的输出上限，防止异常脚本展开超大配置占满内存。
const PreviewOutputLimit = 24 << 20

var (
	ErrCustomTunUnsupported   = errors.New("custom TUN listeners are not supported")
	ErrPreviewCoreUnavailable = errors.New("preview_core_unavailable")
	ErrPreviewInvalidProfile  = errors.New("preview_invalid_profile")
	ErrPreviewNotFound        = errors.New("not_found")
	ErrPreviewInvalidYAML     = errors.New("invalid_yaml")
	ErrPreviewCustomTun       = errors.New("preview_custom_tun")
	ErrPreviewTooLarge        = errors.New("preview_too_large")
	ErrPreviewBuildFailed     = errors.New("preview_build_failed")
)

type PreviewResponse struct {
	Profile         string `json:"profile"`
	BootID          string `json:"bootId"`
	ConfigRevision  uint64 `json:"configRevision"`
	ContentRevision string `json:"contentRevision"`
	ContentHash     string `json:"contentHash"`
	Applied         bool   `json:"applied"`
	RunningProfile  string `json:"runningProfile"`
	CustomRules     bool   `json:"customRules"`
	ScriptIdentity  string `json:"scriptIdentity,omitempty"`
	YAML            string `json:"yaml"`
}

// PreviewBuild 承载锁外生成的预览产物，由引擎在持锁核对运行态身份后组装最终响应。
type PreviewBuild struct {
	Options StartOptions
	Meta    PreviewProfileMeta
	Hash    string
	YAML    string
}

func (p PreviewBuild) ShortHash() string {
	if len(p.Hash) > 12 {
		return p.Hash[:12]
	}
	return p.Hash
}

func BuildRawConfig(ctx context.Context, path string, opts StartOptions) (*mihomoConfig.RawConfig, error) {
	rawCfg, _, err := BuildRawConfigWithHash(ctx, path, opts)
	return rawCfg, err
}

func BuildRawConfigWithHash(ctx context.Context, path string, opts StartOptions) (*mihomoConfig.RawConfig, string, error) {
	if path == "" {
		if opts.Profile != "" {
			return nil, "", errors.New("selected profile requires a configuration path")
		}
		return mihomoConfig.DefaultRawConfig(), "", nil
	}
	buf, err := os.ReadFile(path)
	if err != nil {
		return nil, "", err
	}
	if len(buf) == 0 {
		return nil, "", errors.New("selected configuration is empty")
	}
	sum := sha256.Sum256(buf)
	hash := hex.EncodeToString(sum[:])
	if opts.Script.Enabled() {
		rawCfg, err := ScriptRawConfig(ctx, buf, opts.Script)
		return rawCfg, hash, err
	}
	rawCfg, err := mihomoConfig.UnmarshalRawConfig(buf)
	return rawCfg, hash, err
}

// ComposeRawConfig 组装实际交给 mihomo 的原始配置；运行加载与运行时预览共用同一套规则。
func ComposeRawConfig(rawCfg *mihomoConfig.RawConfig, opts StartOptions) error {
	if opts.Profile != "" && !opts.CustomRules {
		rules := opts.AddedRules.Effective(opts.ProfileRules)
		if err := PrependAddedRules(rawCfg, rules, opts.ProfileRules.MatchTarget, opts.ProfileRules.ExitTargets); err != nil {
			return err
		}
		if err := opts.RuleSets.Attach(rawCfg, opts.HomeDir, rules); err != nil {
			return err
		}
	}
	ApplyOverrides(rawCfg, opts)
	if opts.Profile != "" && opts.DNS.Entries.MissingProxyServers(&rawCfg.DNS) {
		return ErrDNSProxyServersRequired
	}
	// 自定义 TUN 不经过平台 fd 所有权，不能让订阅绕过唯一的系统 VPN。
	for _, mapping := range rawCfg.Listeners {
		if kind, _ := mapping["type"].(string); kind == "tun" {
			return ErrCustomTunUnsupported
		}
	}
	return nil
}

// ApplyOverrides forces the settings ArkClash owns, whatever the profile says.
func ApplyOverrides(rawCfg *mihomoConfig.RawConfig, opts StartOptions) {
	opts.General.Apply(rawCfg)
	// The TUN is created by VpnExtensionAbility and handed over as an fd, so the
	// profile must not try to create its own.
	rawCfg.Tun.Enable = false
	rawCfg.Tun.AutoRoute = false
	rawCfg.Tun.AutoRedirect = false
	rawCfg.Tun.AutoDetectInterface = false
	rawCfg.IPTables.Enable = false

	// 节点选择只从每配置文件恢复，避免 mihomo 全局同名组缓存覆盖它。
	rawCfg.Profile.StoreSelected = false
	// 只有资源管理器可以调度更新，订阅不能覆盖来源或启动第二个更新器。
	rawCfg.GeoXUrl = mihomoConfig.RawGeoXUrl{
		Mmdb: opts.Geo.URLs.MMDB, ASN: opts.Geo.URLs.ASN,
		GeoIp: opts.Geo.URLs.GeoIP, GeoSite: opts.Geo.URLs.GeoSite,
	}
	rawCfg.GeoAutoUpdate = false
	rawCfg.GeoUpdateInterval = opts.Geo.IntervalHours

	// The UI process drives the core over this controller only.
	rawCfg.ExternalController = opts.Controller
	rawCfg.Secret = opts.Secret
	rawCfg.ExternalControllerTLS = ""
	rawCfg.ExternalControllerUnix = ""
	rawCfg.ExternalControllerPipe = ""
	rawCfg.ExternalUI = ""

	// Process lookup scans /proc for every connection and cannot map to apps on
	// HarmonyOS anyway; it only costs battery.
	rawCfg.FindProcessMode = process.FindProcessOff

	// DNS from the TUN is hijacked into mihomo, so the resolver has to be on.
	if !rawCfg.DNS.Enable {
		rawCfg.DNS.Enable = true
		rawCfg.DNS.EnhancedMode = constant.DNSFakeIP
	}
	if opts.Profile != "" {
		opts.DNS.Entries.Apply(&rawCfg.DNS)
		if opts.General.AppendSystemDNS {
			AppendSystemDNS(&rawCfg.DNS)
		}
	}

	// 用户在界面上选过的出站模式和局域网代理优先于配置，热切换后不会被新配置改回去（ADR-0010）。
	if m, ok := tunnel.ModeMapping[strings.ToLower(opts.Mode)]; ok {
		rawCfg.Mode = m
	}
	if opts.AllowLan != nil {
		rawCfg.AllowLan = *opts.AllowLan
	}
}

// BuildPreview 在核心锁外读取磁盘并组装指定配置的完整 YAML 预览。
func BuildPreview(ctx context.Context, base StartOptions, profile string) (PreviewBuild, error) {
	home := base.HomeDir
	meta, err := ReadPreviewProfileMeta(home, profile)
	if err != nil {
		return PreviewBuild{}, SanitizePreviewError(err)
	}

	previewOpts := StartOptions{
		HomeDir:    home,
		ConfigPath: filepath.Join(home, "profiles", profile+".yaml"),
		Controller: base.Controller,
		Secret:     base.Secret,
		Profile:    profile,
		Mode:       base.Mode,
		AllowLan:   base.AllowLan,
	}
	if previewOpts.Geo, err = geo.ReadSettings(home); err != nil {
		return PreviewBuild{}, SanitizePreviewError(err)
	}
	if previewOpts.General, err = ReadGeneralSettings(home); err != nil {
		return PreviewBuild{}, SanitizePreviewError(err)
	}
	if previewOpts.DNS, err = ReadDNSOverrides(home); err != nil {
		return PreviewBuild{}, SanitizePreviewError(err)
	}
	if previewOpts.AddedRules, err = ReadAddedRules(home); err != nil {
		return PreviewBuild{}, SanitizePreviewError(err)
	}
	if previewOpts.RuleSets, err = ReadRuleSets(home); err != nil {
		return PreviewBuild{}, SanitizePreviewError(err)
	}
	if err := LoadProfileExtension(&previewOpts); err != nil {
		return PreviewBuild{}, SanitizePreviewError(err)
	}
	if meta.Kind == "custom" {
		previewOpts.CustomRules = true
	}

	rawCfg, hash, err := BuildRawConfigWithHash(ctx, previewOpts.ConfigPath, previewOpts)
	if err != nil {
		return PreviewBuild{}, SanitizePreviewBuildError(err, previewOpts.Script.Enabled())
	}
	if err := ComposeRawConfig(rawCfg, previewOpts); err != nil {
		return PreviewBuild{}, SanitizePreviewError(err)
	}
	// 内部控制面密钥仅用于同机 IPC，不暴露给预览页面或剪贴板。
	rawCfg.Secret = ""

	var out bytes.Buffer
	encoder := yaml.NewEncoder(&out)
	encoder.SetIndent(2)
	encodeErr := encoder.Encode(rawCfg)
	closeErr := encoder.Close()
	if encodeErr != nil || closeErr != nil {
		return PreviewBuild{}, ErrPreviewBuildFailed
	}
	if out.Len() > PreviewOutputLimit {
		return PreviewBuild{}, ErrPreviewTooLarge
	}

	return PreviewBuild{
		Options: previewOpts,
		Meta:    meta,
		Hash:    hash,
		YAML:    out.String(),
	}, nil
}

// PreviewMatchesCurrent 核对已保存版本、脚本、规则与设置是否与当前运行配置一致。
func PreviewMatchesCurrent(current, preview StartOptions, previewHash string) bool {
	if current.Profile == "" || current.Profile != preview.Profile {
		return false
	}
	if current.ContentHash != "" && previewHash != "" && current.ContentHash != previewHash {
		return false
	}
	if current.CustomRules != preview.CustomRules {
		return false
	}
	if !preview.CustomRules {
		if current.Script.Identity != preview.Script.Identity ||
			current.ProfileRules.Revision != preview.ProfileRules.Revision ||
			current.AddedRules.Revision != preview.AddedRules.Revision ||
			current.RuleSets.Revision != preview.RuleSets.Revision {
			return false
		}
	}
	return current.DNS.Revision == preview.DNS.Revision &&
		current.General.Revision == preview.General.Revision &&
		current.Geo == preview.Geo
}

func SanitizePreviewBuildError(err error, scriptEnabled bool) error {
	if errors.Is(err, os.ErrNotExist) {
		return ErrPreviewNotFound
	}
	var scriptErr *script.Error
	if errors.As(err, &scriptErr) {
		return scriptErr
	}
	if errors.Is(err, ErrScriptConfig) || errors.Is(err, ErrScriptMissing) || errors.Is(err, ErrScriptStore) {
		return err
	}
	if scriptEnabled {
		return ErrScriptConfig
	}
	return ErrPreviewInvalidYAML
}

func SanitizePreviewError(err error) error {
	var scriptErr *script.Error
	if errors.As(err, &scriptErr) {
		return scriptErr
	}
	switch {
	case errors.Is(err, ErrPreviewCoreUnavailable),
		errors.Is(err, ErrPreviewInvalidProfile),
		errors.Is(err, ErrPreviewNotFound),
		errors.Is(err, ErrPreviewInvalidYAML),
		errors.Is(err, ErrPreviewTooLarge),
		errors.Is(err, ErrScriptMissing),
		errors.Is(err, ErrScriptStore),
		errors.Is(err, ErrScriptConfig),
		errors.Is(err, ErrAddedRulesMatchTarget),
		errors.Is(err, ErrDNSProxyServersRequired),
		errors.Is(err, ErrRuleSetInUse),
		errors.Is(err, ErrRuleSetInput),
		errors.Is(err, ruleset.ErrContent),
		errors.Is(err, ErrSettingsInvalid),
		errors.Is(err, ErrSettingsIO),
		errors.Is(err, ErrDNSInvalid),
		errors.Is(err, ErrDNSIO),
		errors.Is(err, ErrGeneralInvalid),
		errors.Is(err, ErrGeneralIO):
		return err
	case errors.Is(err, ErrCustomTunUnsupported):
		return ErrPreviewCustomTun
	default:
		return ErrPreviewBuildFailed
	}
}
