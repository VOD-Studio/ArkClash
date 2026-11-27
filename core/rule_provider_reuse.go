package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"maps"

	"github.com/metacubex/mihomo/config"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/hub/executor"
	RP "github.com/metacubex/mihomo/rules/provider"
)

// 热切换时复用定义没变、已经加载好的 rule provider（ADR-0043）。应用配置期间 tunnel 挂起，
// 新连接会失败；几十万条的域名规则集重新解析一遍要好几秒，保存一条附加规则也要等这么久。

// ruleProviderGeneration 是最近一次生效配置里的 rule provider，存在 eng.ruleProviders。发布后只读，整份替换。
type ruleProviderGeneration struct {
	keys      map[string]string // provider 名 → 定义指纹，来自 ruleProviderKeys
	providers map[string]P.RuleProvider
}

// installRuleProviderReuse 在每次启动内核时登记 mihomo 钩子；登记本身是原子的，重复调用无害。
func installRuleProviderReuse() {
	config.ArkClashSetRuleProviderReuse(reuseRuleProvider)
	executor.ArkClashSetProviderLoaded(ruleProviderLoaded)
}

// ruleProviderKeys 在 config.ParseRawConfig 之前计算，和 reuseRuleProvider 在解析时看到的是同一份定义。
func ruleProviderKeys(raw map[string]map[string]any) map[string]string {
	keys := make(map[string]string, len(raw))
	for name, mapping := range raw {
		if key, ok := ruleProviderKey(mapping); ok {
			keys[name] = key
		}
	}
	return keys
}

// 定义来自 YAML 或脚本输出，都能编码成 JSON；json.Marshal 按键排序，同一份定义得到同一个指纹。
// 编码失败就不给指纹，这个 provider 照常新建。
func ruleProviderKey(mapping map[string]any) (string, bool) {
	buf, err := json.Marshal(mapping)
	if err != nil {
		return "", false
	}
	sum := sha256.Sum256(buf)
	return hex.EncodeToString(sum[:]), true
}

// reuseRuleProvider 可能在核心锁外被并发调用（预览、校验），只读已发布的那一代。
func reuseRuleProvider(name string, mapping map[string]any) (P.RuleProvider, bool) {
	applied := eng.ruleProviders.Load()
	if applied == nil {
		return nil, false
	}
	previous, ok := applied.keys[name]
	if !ok {
		return nil, false
	}
	if key, ok := ruleProviderKey(mapping); !ok || key != previous {
		return nil, false
	}
	live, ok := applied.providers[name]
	if !ok || !reusableRuleProvider(live) {
		return nil, false
	}
	return live, true
}

// 只复用纯数据的 Domain、IPCIDR 规则集：Classical 的每一行经 ParseRule 解析，可能用到 Geo 数据这类
// 两份配置之间会变的状态；Inline 的内容就在配置里，重新解析很便宜。上次没加载出内容的实例也不复用，
// 让新配置照常重试。地址、路径、间隔相同时，下载和文件监听都由原实例继续负责。
func reusableRuleProvider(rp P.RuleProvider) bool {
	if _, ok := rp.(*RP.RuleSetProvider); !ok {
		return false
	}
	switch rp.Behavior() {
	case P.Domain, P.IPCIDR:
	default:
		return false
	}
	switch rp.VehicleType() {
	case P.HTTP, P.File:
	default:
		return false
	}
	return rp.Count() > 0
}

// ruleProviderLoaded 判断 provider 是不是上一代里正在运行的那个实例。只比较 *RuleSetProvider 指针：
// 接口相等比较遇到不可比较的动态类型会 panic。
func ruleProviderLoaded(pv P.Provider) bool {
	applied := eng.ruleProviders.Load()
	candidate, ok := pv.(*RP.RuleSetProvider)
	if applied == nil || !ok {
		return false
	}
	live, ok := applied.providers[candidate.Name()].(*RP.RuleSetProvider)
	return ok && live == candidate
}

// publishRuleProvidersLocked 在 executor.ApplyConfig 之后记下实际生效的 rule provider。cfg 为 nil 时清空，
// 内核停止后不会把上一轮的实例带进下一次启动。调用方持有核心 mu。
func publishRuleProvidersLocked(cfg *config.Config, keys map[string]string) {
	if cfg == nil {
		eng.ruleProviders.Store(nil)
		return
	}
	eng.ruleProviders.Store(&ruleProviderGeneration{keys: keys, providers: maps.Clone(cfg.RuleProviders)})
}
