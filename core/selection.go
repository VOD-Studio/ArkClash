package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"

	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

type selectionRequest struct {
	Profile          string `json:"profile"`
	Group            string `json:"group"`
	Name             string `json:"name"`
	NodeID           string `json:"nodeId"`
	ClearPin         bool   `json:"clearPin"`
	CloseConnections bool   `json:"closeConnections"`
	OperationID      string `json:"operationId"`
	ExpectedBootID   string `json:"expectedBootId"`
	ExpectedRevision uint64 `json:"expectedRevision"`
}

type selectionResult struct {
	Changed       bool   `json:"changed"`
	Selected      string `json:"selected"`
	SelectedID    string `json:"selectedId"`
	Pinned        string `json:"pinned"`
	CleanupFailed bool   `json:"cleanupFailed"`
}

type selectionOperation struct {
	Request selectionRequest
	Result  selectionResult
}

func selectionPath(home, profile string) string {
	return filepath.Join(home, "profiles", profile+".selected.json")
}

func readSelections(home, profile string) (map[string]string, error) {
	body, err := os.ReadFile(selectionPath(home, profile))
	if errors.Is(err, os.ErrNotExist) {
		return make(map[string]string), nil
	}
	if err != nil {
		return nil, errors.New("selection_read_failed")
	}
	var selected map[string]string
	if json.Unmarshal(body, &selected) != nil || selected == nil {
		return nil, errors.New("selection_read_failed")
	}
	return selected, nil
}

func saveSelections(home, profile string, selected map[string]string) error {
	path := selectionPath(home, profile)
	file, err := os.CreateTemp(filepath.Dir(path), ".selected-*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	if err := json.NewEncoder(file).Encode(selected); err != nil {
		file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return os.Rename(file.Name(), path)
}

// 在启用转发之前恢复配置自己的选择；provider 成员尚未初始化时由组在加载后解析。
func restoreSelections(cfg *config.Config, opts startOptions) error {
	if opts.Profile == "" {
		return nil
	}
	selected, err := readSelections(opts.HomeDir, opts.Profile)
	if err != nil {
		return err
	}
	for name, target := range selected {
		proxy := cfg.Proxies[name]
		if proxy == nil || (proxy.Type() != C.Selector && proxy.Type() != C.URLTest && proxy.Type() != C.Fallback) {
			continue
		}
		if group, ok := proxy.Adapter().(outboundgroup.SelectAble); ok {
			group.ForceSet(target)
		}
	}
	return nil
}

func checkSelectionNode(req selectionRequest, group outboundgroup.ProxyGroup) error {
	if req.ClearPin {
		return nil
	}
	target, valid := currentProxyMember(req.NodeID, req.Group)
	if !valid || target.Name() != req.Name {
		return errors.New("selection_node_unavailable")
	}
	for _, member := range group.Proxies() {
		if member.Name() == req.Name && member != target {
			return errors.New("selection_node_not_addressable")
		}
	}
	return nil
}

func commitSelection(req selectionRequest) (selectionResult, error) {
	var res selectionResult
	err := eng.withState(func(tx *stateTx) error {
		var err error
		res, err = commitSelectionLocked(req)
		return err
	})
	return res, err
}

func commitSelectionLocked(req selectionRequest) (selectionResult, error) {
	if !eng.running || eng.current.Profile == "" || req.Profile != eng.current.Profile {
		return selectionResult{}, errors.New("selection_profile_changed")
	}
	if req.OperationID == "" || len(req.OperationID) > 96 || req.Group == "" || len(req.Group) > 1024 || len(req.Name) > 1024 {
		return selectionResult{}, errors.New("invalid_selection")
	}
	if req.ExpectedBootID != eng.bootID || req.ExpectedRevision != eng.configRevision {
		return selectionResult{}, errors.New("selection_revision_changed")
	}
	proxy := tunnel.Proxies()[req.Group]
	if proxy == nil || (proxy.Type() != C.Selector && proxy.Type() != C.URLTest && proxy.Type() != C.Fallback) {
		return selectionResult{}, errors.New("selection_group_not_selectable")
	}
	group, ok := proxy.Adapter().(outboundgroup.ProxyGroup)
	if !ok {
		return selectionResult{}, errors.New("selection_group_not_selectable")
	}
	selectable, ok := proxy.Adapter().(outboundgroup.SelectAble)
	if !ok || req.ClearPin && proxy.Type() == C.Selector || !req.ClearPin && req.Name == "" {
		return selectionResult{}, errors.New("invalid_selection")
	}
	if err := checkSelectionNode(req, group); err != nil {
		return selectionResult{}, err
	}
	if prior, ok := eng.selections.ops[req.OperationID]; ok {
		if prior.Request != req {
			return selectionResult{}, errors.New("selection_operation_conflict")
		}
		return prior.Result, nil
	}
	selected, err := readSelections(eng.current.HomeDir, eng.current.Profile)
	if err != nil {
		return selectionResult{}, err
	}
	priorPin, hadPriorPin := selected[req.Group]
	priorTarget := priorPin
	if proxy.Type() == C.Selector {
		priorTarget = group.Now()
	}
	target := req.Name
	if req.ClearPin {
		target = ""
	}
	changed := priorTarget != target
	if changed {
		if req.ClearPin {
			selectable.ForceSet("")
		} else if err := selectable.Set(target); err != nil {
			return selectionResult{}, errors.New("selection_node_unavailable")
		}
	}
	if err := checkSelectionNode(req, group); err != nil {
		selectable.ForceSet(priorTarget)
		eng.publishRuntimeLocked()
		return selectionResult{}, err
	}
	if target == "" {
		delete(selected, req.Group)
	} else {
		selected[req.Group] = target
	}
	if priorPin != target {
		if err := saveSelections(eng.current.HomeDir, eng.current.Profile, selected); err != nil {
			if changed {
				selectable.ForceSet(priorTarget)
				if proxy.Type() == C.Selector && group.Now() != priorTarget {
					eng.publishRuntimeLocked()
					return selectionResult{}, errors.New("selection_inconsistent")
				}
			}
			return selectionResult{}, errors.New("selection_persist_failed")
		}
	}
	if err := checkSelectionNode(req, group); err != nil {
		selectable.ForceSet(priorTarget)
		if priorPin != target {
			if hadPriorPin {
				selected[req.Group] = priorPin
			} else {
				delete(selected, req.Group)
			}
			if saveSelections(eng.current.HomeDir, eng.current.Profile, selected) != nil {
				eng.publishRuntimeLocked()
				return selectionResult{}, errors.New("selection_inconsistent")
			}
		}
		eng.publishRuntimeLocked()
		return selectionResult{}, err
	}
	graph := currentProxyGraph()
	result := selectionResult{Changed: changed, Selected: group.Now(), SelectedID: graph.Actual[req.Group], Pinned: target}
	if proxy.Type() == C.Selector {
		result.Pinned = ""
	}
	if changed {
		closeConnections := req.CloseConnections
		if eng.current.General.CloseConnections != nil {
			closeConnections = *eng.current.General.CloseConnections
		}
		if closeConnections {
			statistic.DefaultManager.Range(func(connection statistic.Tracker) bool {
				if connection.Close() != nil {
					result.CleanupFailed = true
				}
				return true
			})
		} else {
			resolver.ResetConnection()
		}
	}
	if eng.selections.ops == nil {
		eng.selections.ops = make(map[string]selectionOperation)
	}
	if len(eng.selections.order) >= 128 {
		delete(eng.selections.ops, eng.selections.order[0])
		eng.selections.order = eng.selections.order[1:]
	}
	eng.selections.ops[req.OperationID] = selectionOperation{Request: req, Result: result}
	eng.selections.order = append(eng.selections.order, req.OperationID)
	if changed {
		eng.publishRuntimeLocked()
	}
	return result, nil
}

func postSelection(w http.ResponseWriter, r *http.Request) {
	var request selectionRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192)).Decode(&request); err != nil {
		writeError(w, r, http.StatusBadRequest, errors.New("invalid_selection"))
		return
	}
	result, err := commitSelection(request)
	if err != nil {
		writeError(w, r, http.StatusConflict, err)
		return
	}
	render.JSON(w, r, result)
}

func getSelections(w http.ResponseWriter, r *http.Request) {
	var (
		profile  string
		selected map[string]string
		notReady bool
	)
	err := eng.withState(func(tx *stateTx) error {
		if !eng.running || eng.current.Profile == "" {
			notReady = true
			return nil
		}
		profile = eng.current.Profile
		var err error
		selected, err = readSelections(eng.current.HomeDir, profile)
		return err
	})
	if notReady {
		writeError(w, r, http.StatusConflict, errors.New("selection_profile_changed"))
		return
	}
	if err != nil {
		writeError(w, r, http.StatusInternalServerError, err)
		return
	}
	render.JSON(w, r, struct {
		Profile  string            `json:"profile"`
		Selected map[string]string `json:"selected"`
	}{Profile: profile, Selected: selected})
}
