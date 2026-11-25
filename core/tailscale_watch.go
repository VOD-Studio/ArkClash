package main

import "sync"

type tailscaleNetworkWatches struct {
	mu         sync.Mutex
	callbackID uint32
	registered bool
	users      int
	listeners  sync.Map
}

func (w *tailscaleNetworkWatches) changed() {
	// 注册和注销可能同步触发回调，不能在此取得管理注册状态的锁。
	w.listeners.Range(func(_, value any) bool {
		value.(func())()
		return true
	})
}

func (w *tailscaleNetworkWatches) subscribe(notify func(), register func() (uint32, error),
	unregister func(uint32) error) (func() error, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.listeners.Store(&notify, notify)
	if !w.registered {
		id, err := register()
		if err != nil {
			w.listeners.Delete(&notify)
			return nil, err
		}
		w.callbackID = id
		w.registered = true
	}
	w.users++
	return sync.OnceValue(func() error {
		w.mu.Lock()
		defer w.mu.Unlock()
		w.listeners.Delete(&notify)
		w.users--
		if w.users != 0 {
			return nil
		}
		if err := unregister(w.callbackID); err != nil {
			// 系统可能仍持有注册。后续节点复用原回调，最后一次释放时再尝试注销。
			return err
		}
		w.registered = false
		return nil
	}), nil
}
