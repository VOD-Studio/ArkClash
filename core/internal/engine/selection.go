package engine

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"

	corecfg "github.com/VOD-Studio/ArkClash/core/internal/config"
	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

type SelectionRequest struct {
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

type SelectionResult struct {
	Changed       bool   `json:"changed"`
	Selected      string `json:"selected"`
	SelectedID    string `json:"selectedId"`
	Pinned        string `json:"pinned"`
	CleanupFailed bool   `json:"cleanupFailed"`
}

type SelectionsResponse struct {
	Profile  string            `json:"profile"`
	Selected map[string]string `json:"selected"`
}

type selectionOperation struct {
	Request SelectionRequest
	Result  SelectionResult
}

func SelectionPath(home, profile string) string {
	return filepath.Join(home, "profiles", profile+".selected.json")
}

func ReadSelections(home, profile string) (map[string]string, error) {
	body, err := os.ReadFile(SelectionPath(home, profile))
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

func SaveSelections(home, profile string, selected map[string]string) error {
	path := SelectionPath(home, profile)
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
func RestoreSelections(cfg *config.Config, opts corecfg.StartOptions) error {
	if opts.Profile == "" {
		return nil
	}
	selected, err := ReadSelections(opts.HomeDir, opts.Profile)
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

func (e *Engine) checkSelectionNodeLocked(req SelectionRequest, group outboundgroup.ProxyGroup) error {
	if req.ClearPin {
		return nil
	}
	target, valid := e.currentProxyMemberLocked(req.NodeID, req.Group)
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

func (e *Engine) CommitSelection(req SelectionRequest) (SelectionResult, error) {
	var res SelectionResult
	err := e.withState(func(tx *stateTx) error {
		var err error
		res, err = e.commitSelectionLocked(req)
		return err
	})
	return res, err
}

func (e *Engine) commitSelectionLocked(req SelectionRequest) (SelectionResult, error) {
	if !e.running || e.current.Profile == "" || req.Profile != e.current.Profile {
		return SelectionResult{}, errors.New("selection_profile_changed")
	}
	if req.OperationID == "" || len(req.OperationID) > 96 || req.Group == "" || len(req.Group) > 1024 || len(req.Name) > 1024 {
		return SelectionResult{}, errors.New("invalid_selection")
	}
	if req.ExpectedBootID != e.bootID || req.ExpectedRevision != e.configRevision {
		return SelectionResult{}, errors.New("selection_revision_changed")
	}
	proxy := tunnel.Proxies()[req.Group]
	if proxy == nil || (proxy.Type() != C.Selector && proxy.Type() != C.URLTest && proxy.Type() != C.Fallback) {
		return SelectionResult{}, errors.New("selection_group_not_selectable")
	}
	group, ok := proxy.Adapter().(outboundgroup.ProxyGroup)
	if !ok {
		return SelectionResult{}, errors.New("selection_group_not_selectable")
	}
	selectable, ok := proxy.Adapter().(outboundgroup.SelectAble)
	if !ok || req.ClearPin && proxy.Type() == C.Selector || !req.ClearPin && req.Name == "" {
		return SelectionResult{}, errors.New("invalid_selection")
	}
	if err := e.checkSelectionNodeLocked(req, group); err != nil {
		return SelectionResult{}, err
	}
	if prior, ok := e.selections.ops[req.OperationID]; ok {
		if prior.Request != req {
			return SelectionResult{}, errors.New("selection_operation_conflict")
		}
		return prior.Result, nil
	}
	selected, err := ReadSelections(e.current.HomeDir, e.current.Profile)
	if err != nil {
		return SelectionResult{}, err
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
			return SelectionResult{}, errors.New("selection_node_unavailable")
		}
	}
	if err := e.checkSelectionNodeLocked(req, group); err != nil {
		selectable.ForceSet(priorTarget)
		e.publishRuntimeLocked()
		return SelectionResult{}, err
	}
	if target == "" {
		delete(selected, req.Group)
	} else {
		selected[req.Group] = target
	}
	if priorPin != target {
		if err := SaveSelections(e.current.HomeDir, e.current.Profile, selected); err != nil {
			if changed {
				selectable.ForceSet(priorTarget)
				if proxy.Type() == C.Selector && group.Now() != priorTarget {
					e.publishRuntimeLocked()
					return SelectionResult{}, errors.New("selection_inconsistent")
				}
			}
			return SelectionResult{}, errors.New("selection_persist_failed")
		}
	}
	if err := e.checkSelectionNodeLocked(req, group); err != nil {
		selectable.ForceSet(priorTarget)
		if priorPin != target {
			if hadPriorPin {
				selected[req.Group] = priorPin
			} else {
				delete(selected, req.Group)
			}
			if SaveSelections(e.current.HomeDir, e.current.Profile, selected) != nil {
				e.publishRuntimeLocked()
				return SelectionResult{}, errors.New("selection_inconsistent")
			}
		}
		e.publishRuntimeLocked()
		return SelectionResult{}, err
	}
	graph := e.currentProxyGraphLocked()
	result := SelectionResult{Changed: changed, Selected: group.Now(), SelectedID: graph.Actual[req.Group], Pinned: target}
	if proxy.Type() == C.Selector {
		result.Pinned = ""
	}
	if changed {
		closeConnections := req.CloseConnections
		if e.current.General.CloseConnections != nil {
			closeConnections = *e.current.General.CloseConnections
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
	if e.selections.ops == nil {
		e.selections.ops = make(map[string]selectionOperation)
	}
	if len(e.selections.order) >= 128 {
		delete(e.selections.ops, e.selections.order[0])
		e.selections.order = e.selections.order[1:]
	}
	e.selections.ops[req.OperationID] = selectionOperation{Request: req, Result: result}
	e.selections.order = append(e.selections.order, req.OperationID)
	if changed {
		e.publishRuntimeLocked()
	}
	return result, nil
}

func (e *Engine) GetSelections() (SelectionsResponse, int, error) {
	var (
		profile  string
		selected map[string]string
		notReady bool
	)
	err := e.withState(func(tx *stateTx) error {
		if !e.running || e.current.Profile == "" {
			notReady = true
			return nil
		}
		profile = e.current.Profile
		var err error
		selected, err = ReadSelections(e.current.HomeDir, profile)
		return err
	})
	if notReady {
		return SelectionsResponse{}, http.StatusConflict, errors.New("selection_profile_changed")
	}
	if err != nil {
		return SelectionsResponse{}, http.StatusInternalServerError, err
	}
	return SelectionsResponse{Profile: profile, Selected: selected}, http.StatusOK, nil
}
