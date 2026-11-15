package main

import (
	"errors"
	"strconv"

	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	C "github.com/metacubex/mihomo/constant"
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

var proxyIdentityBoot string
var proxyIdentityRevision uint64
var proxyIdentitySequence uint64
var proxyIdentities map[C.Proxy]string
var identifiedProxies map[string]C.Proxy

// 调用方持有 mu；实例不再被当前成员或实际出站引用后，旧 ID 不会复用。
func resetProxyIdentities() {
	proxyIdentityBoot = runtimeBootID
	proxyIdentityRevision = runtimeConfigRevision
	proxyIdentities = make(map[C.Proxy]string)
	identifiedProxies = make(map[string]C.Proxy)
}

func currentProxyGraph() proxySnapshotResponse {
	if proxyIdentities == nil || proxyIdentityBoot != runtimeBootID || proxyIdentityRevision != runtimeConfigRevision {
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
		id, exists := proxyIdentities[node]
		if !exists {
			proxyIdentitySequence++
			id = runtimeBootID + "." + strconv.FormatUint(runtimeConfigRevision, 36) + "." + strconv.FormatUint(proxyIdentitySequence, 36)
			proxyIdentities[node] = id
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
	proxyIdentities = live
	identifiedProxies = result.Nodes
	return result
}

func captureProxySnapshot() (proxySnapshotResponse, error) {
	mu.Lock()
	defer mu.Unlock()
	if !running {
		return proxySnapshotResponse{}, errors.New("core_not_running")
	}
	return currentProxyGraph(), nil
}

// ID 必须同时属于当前实例与当前组；不能退回按显示名查找。
func currentProxyMember(id, groupName string) (C.Proxy, bool) {
	if proxyIdentityBoot != runtimeBootID || proxyIdentityRevision != runtimeConfigRevision {
		return nil, false
	}
	proxy := identifiedProxies[id]
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
