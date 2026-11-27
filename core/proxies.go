package main

import (
	"encoding/json"
	"errors"
	"strconv"

	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/tunnel"
)

type proxyReference struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Provider   string `json:"provider,omitempty"`
	Selectable bool   `json:"selectable"`
}

type proxySnapshotResponse struct {
	Proxies map[string]proxyReference   `json:"proxies"`
	Nodes   map[string]C.Proxy          `json:"nodes"`
	Members map[string][]proxyReference `json:"members"`
	Actual  map[string]string           `json:"actual"`
	Retired map[string]bool             `json:"retired"`
}

// 调用方持有 eng.mu；实例不再被当前成员或实际出站引用后，旧 ID 不会复用。
func resetProxyIdentities() {
	eng.proxies.boot = eng.bootID
	eng.proxies.revision = eng.configRevision
	eng.proxies.byProxy = make(map[C.Proxy]string)
	eng.proxies.byID = make(map[string]C.Proxy)
}

func currentProxyGraph() proxySnapshotResponse {
	if eng.proxies.byProxy == nil || eng.proxies.boot != eng.bootID || eng.proxies.revision != eng.configRevision {
		resetProxyIdentities()
	}
	proxies := tunnel.Proxies()
	result := proxySnapshotResponse{
		Proxies: make(map[string]proxyReference, len(proxies)), Nodes: make(map[string]C.Proxy),
		Members: make(map[string][]proxyReference), Actual: make(map[string]string), Retired: make(map[string]bool),
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
	reference := func(node C.Proxy) proxyReference {
		id, exists := eng.proxies.byProxy[node]
		if !exists {
			eng.proxies.sequence++
			id = eng.bootID + "." + strconv.FormatUint(eng.configRevision, 36) + "." + strconv.FormatUint(eng.proxies.sequence, 36)
			eng.proxies.byProxy[node] = id
		}
		live[node] = id
		result.Nodes[id] = node
		return proxyReference{ID: id, Name: node.Name(), Provider: providers[node], Selectable: true}
	}
	for name, proxy := range proxies {
		result.Proxies[name] = reference(proxy)
		group, ok := proxy.Adapter().(outboundgroup.ProxyGroup)
		if !ok {
			continue
		}
		nodes := group.Proxies()
		members := make([]proxyReference, 0, len(nodes))
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
	eng.proxies.byProxy = live
	eng.proxies.byID = result.Nodes
	return result
}

func captureProxySnapshot() (proxySnapshotResponse, error) {
	var snapshot proxySnapshotResponse
	err := eng.withState(func(tx *stateTx) error {
		if !eng.running {
			return errors.New("core_not_running")
		}
		if eng.current.Profile == "" {
			return errors.New("core_profile_unavailable")
		}
		snapshot = currentProxyGraph()
		return nil
	})
	return snapshot, err
}

// ID 必须同时属于当前实例与当前组；不能退回按显示名查找。
func currentProxyMember(id, groupName string) (C.Proxy, bool) {
	if !eng.running || eng.current.Profile == "" || eng.proxies.boot != eng.bootID || eng.proxies.revision != eng.configRevision {
		return nil, false
	}
	proxy := eng.proxies.byID[id]
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

func getProxySnapshot(w http.ResponseWriter, r *http.Request) {
	snapshot, err := captureProxySnapshot()
	if err != nil {
		writeError(w, r, http.StatusConflict, err)
		return
	}
	render.JSON(w, r, snapshot)
}

type proxyDefinitionRequest struct {
	BootID         string `json:"bootId"`
	ConfigRevision uint64 `json:"configRevision"`
	ID             string `json:"id"`
	Group          string `json:"group"`
}

type proxyDefinitionResponse struct {
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

func isBuiltinProxyType(kind C.AdapterType) bool {
	switch kind {
	case C.Direct, C.Reject, C.RejectDrop, C.Compatible, C.Pass, C.Dns:
		return true
	default:
		return false
	}
}

// 调用方持有 eng.mu，身份必须同时匹配宿主、配置修订和组内成员。
func lookupProxyLocked(req proxyDefinitionRequest) (C.Proxy, int, error) {
	if req.BootID == "" || req.ConfigRevision == 0 || req.ID == "" {
		return nil, http.StatusBadRequest, errors.New("proxy_invalid_request")
	}
	if !eng.running {
		return nil, http.StatusConflict, errors.New("core_not_running")
	}
	if eng.current.Profile == "" {
		return nil, http.StatusConflict, errors.New("core_profile_unavailable")
	}
	if req.BootID != eng.bootID || req.ConfigRevision != eng.configRevision {
		return nil, http.StatusConflict, errors.New("proxy_stale_config")
	}
	proxy, ok := currentProxyMember(req.ID, req.Group)
	if !ok {
		return nil, http.StatusNotFound, errors.New("proxy_not_found")
	}
	return proxy, http.StatusOK, nil
}

func lookupProxyDefinition(req proxyDefinitionRequest) (proxyDefinitionResponse, int, error) {
	var (
		res    proxyDefinitionResponse
		status int
	)
	err := eng.withState(func(tx *stateTx) error {
		var err error
		proxy, code, err := lookupProxyLocked(req)
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
		res = proxyDefinitionResponse{
			BootID:         eng.bootID,
			ConfigRevision: eng.configRevision,
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

func postProxyDefinition(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 32<<10)
	var body proxyDefinitionRequest
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, r, http.StatusBadRequest, errors.New("proxy_invalid_request"))
		return
	}
	result, status, err := lookupProxyDefinition(body)
	if err != nil {
		writeError(w, r, status, err)
		return
	}
	render.JSON(w, r, result)
}
