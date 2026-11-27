package engine

import (
	"errors"
	"strconv"

	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/tunnel"
)

type ProxyReference struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Provider   string `json:"provider,omitempty"`
	Selectable bool   `json:"selectable"`
}

type ProxySnapshotResponse struct {
	Proxies map[string]ProxyReference   `json:"proxies"`
	Nodes   map[string]C.Proxy          `json:"nodes"`
	Members map[string][]ProxyReference `json:"members"`
	Actual  map[string]string           `json:"actual"`
	Retired map[string]bool             `json:"retired"`
}

type ProxyDefinitionRequest struct {
	BootID         string `json:"bootId"`
	ConfigRevision uint64 `json:"configRevision"`
	ID             string `json:"id"`
	Group          string `json:"group"`
}

type ProxyDefinitionResponse struct {
	BootID         string         `json:"bootId"`
	ConfigRevision uint64         `json:"configRevision"`
	ID             string         `json:"id"`
	Name           string         `json:"name"`
	Provider       string         `json:"provider,omitempty"`
	Definition     map[string]any `json:"definition"`
}

type rawDefinitionProvider interface {
	ArkClashRawDefinition() map[string]any
}

// 调用方持有 e.mu；实例不再被当前成员或实际出站引用后，旧 ID 不会复用。
func (e *Engine) resetProxyIdentitiesLocked() {
	e.proxies.boot = e.bootID
	e.proxies.revision = e.configRevision
	e.proxies.byProxy = make(map[C.Proxy]string)
	e.proxies.byID = make(map[string]C.Proxy)
}

func (e *Engine) currentProxyGraphLocked() ProxySnapshotResponse {
	if e.proxies.byProxy == nil || e.proxies.boot != e.bootID || e.proxies.revision != e.configRevision {
		e.resetProxyIdentitiesLocked()
	}
	proxies := tunnel.Proxies()
	result := ProxySnapshotResponse{
		Proxies: make(map[string]ProxyReference, len(proxies)), Nodes: make(map[string]C.Proxy),
		Members: make(map[string][]ProxyReference), Actual: make(map[string]string), Retired: make(map[string]bool),
	}
	providers := make(map[C.Proxy]string)
	for name, provider := range tunnel.Providers() {
		for _, node := range provider.Proxies() {
			if prior, exists := providers[node]; !exists || name < prior {
				providers[node] = name
			}
		}
	}
	live := make(map[C.Proxy]string)
	reference := func(node C.Proxy) ProxyReference {
		id, exists := e.proxies.byProxy[node]
		if !exists {
			e.proxies.sequence++
			id = e.bootID + "." + strconv.FormatUint(e.configRevision, 36) + "." + strconv.FormatUint(e.proxies.sequence, 36)
			e.proxies.byProxy[node] = id
		}
		live[node] = id
		result.Nodes[id] = node
		return ProxyReference{ID: id, Name: node.Name(), Provider: providers[node], Selectable: true}
	}
	for name, proxy := range proxies {
		result.Proxies[name] = reference(proxy)
		group, ok := proxy.Adapter().(outboundgroup.ProxyGroup)
		if !ok {
			continue
		}
		nodes := group.Proxies()
		members := make([]ProxyReference, 0, len(nodes))
		seen := make(map[C.Proxy]struct{}, len(nodes))
		names := make(map[string]int, len(nodes))
		for _, node := range nodes {
			if _, duplicate := seen[node]; duplicate {
				continue
			}
			seen[node] = struct{}{}
			names[node.Name()]++
			members = append(members, reference(node))
		}
		// Set(name) 无法表达同名实例身份，任何同名卡片都不能声称可精确指定。
		for index := range members {
			members[index].Selectable = names[members[index].Name] == 1
		}
		result.Members[name] = members
	}
	// 自动组的缓存仍可能采用已被 provider 替换的实例；实际出站不能被当前成员过滤掉。
	for name, proxy := range proxies {
		if proxy.Type() != C.Selector && proxy.Type() != C.URLTest && proxy.Type() != C.Fallback {
			continue
		}
		actual := proxy.Unwrap(nil, false)
		if actual == nil {
			continue
		}
		_, member := live[actual]
		_, provided := providers[actual]
		ref := reference(actual)
		result.Actual[name] = ref.ID
		if !member && !provided {
			result.Retired[ref.ID] = true
		}
	}
	e.proxies.byProxy = live
	e.proxies.byID = result.Nodes
	return result
}

func (e *Engine) CaptureProxySnapshot() (ProxySnapshotResponse, error) {
	var snapshot ProxySnapshotResponse
	err := e.withState(func(tx *stateTx) error {
		if !e.running {
			return errors.New("core_not_running")
		}
		if e.current.Profile == "" {
			return errors.New("core_profile_unavailable")
		}
		snapshot = e.currentProxyGraphLocked()
		return nil
	})
	return snapshot, err
}

// ID 必须同时属于当前实例与当前组；不能退回按显示名查找。
func (e *Engine) currentProxyMemberLocked(id, groupName string) (C.Proxy, bool) {
	if !e.running || e.current.Profile == "" || e.proxies.boot != e.bootID || e.proxies.revision != e.configRevision {
		return nil, false
	}
	proxy := e.proxies.byID[id]
	if proxy == nil {
		return nil, false
	}
	if groupName == "" {
		for _, candidate := range tunnel.Proxies() {
			if candidate == proxy {
				return proxy, true
			}
		}
		for _, provider := range tunnel.Providers() {
			for _, candidate := range provider.Proxies() {
				if candidate == proxy {
					return proxy, true
				}
			}
		}
		return nil, false
	}
	groupProxy := tunnel.Proxies()[groupName]
	if groupProxy == nil {
		return nil, false
	}
	group, ok := groupProxy.Adapter().(outboundgroup.ProxyGroup)
	if !ok {
		return nil, false
	}
	for _, member := range group.Proxies() {
		if member == proxy {
			return proxy, true
		}
	}
	return nil, false
}

func isBuiltinProxyType(kind C.AdapterType) bool {
	switch kind {
	case C.Direct, C.Reject, C.RejectDrop, C.Compatible, C.Pass, C.Dns:
		return true
	default:
		return false
	}
}

// 调用方持有 e.mu，身份必须同时匹配宿主、配置修订和组内成员。
func (e *Engine) lookupProxyLocked(req ProxyDefinitionRequest) (C.Proxy, int, error) {
	if req.BootID == "" || req.ConfigRevision == 0 || req.ID == "" {
		return nil, http.StatusBadRequest, errors.New("proxy_invalid_request")
	}
	if !e.running {
		return nil, http.StatusConflict, errors.New("core_not_running")
	}
	if e.current.Profile == "" {
		return nil, http.StatusConflict, errors.New("core_profile_unavailable")
	}
	if req.BootID != e.bootID || req.ConfigRevision != e.configRevision {
		return nil, http.StatusConflict, errors.New("proxy_stale_config")
	}
	proxy, ok := e.currentProxyMemberLocked(req.ID, req.Group)
	if !ok {
		return nil, http.StatusNotFound, errors.New("proxy_not_found")
	}
	return proxy, http.StatusOK, nil
}

func (e *Engine) LookupProxyDefinition(req ProxyDefinitionRequest) (ProxyDefinitionResponse, int, error) {
	var (
		res    ProxyDefinitionResponse
		status int
	)
	err := e.withState(func(tx *stateTx) error {
		proxy, code, err := e.lookupProxyLocked(req)
		if err != nil {
			status = code
			return err
		}
		if _, isGroup := proxy.Adapter().(outboundgroup.ProxyGroup); isGroup || isBuiltinProxyType(proxy.Type()) {
			status = http.StatusBadRequest
			return errors.New("proxy_not_exportable")
		}
		exporter, ok := proxy.(rawDefinitionProvider)
		if !ok {
			status = http.StatusBadRequest
			return errors.New("proxy_not_exportable")
		}
		definition := exporter.ArkClashRawDefinition()
		if len(definition) == 0 {
			status = http.StatusBadRequest
			return errors.New("proxy_not_exportable")
		}
		if name, _ := definition["name"].(string); name == "" {
			definition["name"] = proxy.Name()
		}
		providerName := proxy.ProxyInfo().ProviderName
		if providerName == "" {
			for name, item := range tunnel.Providers() {
				if item.VehicleType() == P.Compatible {
					continue
				}
				for _, candidate := range item.Proxies() {
					if candidate == proxy && (providerName == "" || name < providerName) {
						providerName = name
					}
				}
			}
		}
		res = ProxyDefinitionResponse{
			BootID:         e.bootID,
			ConfigRevision: e.configRevision,
			ID:             req.ID,
			Name:           proxy.Name(),
			Provider:       providerName,
			Definition:     definition,
		}
		status = http.StatusOK
		return nil
	})
	return res, status, err
}
