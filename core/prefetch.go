package main

import (
	"errors"
	"os"
	"sync"
	"sync/atomic"

	"github.com/metacubex/mihomo/config"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/log"
	R "github.com/metacubex/mihomo/rules"
	RB "github.com/metacubex/mihomo/rules/bundle"
	RP "github.com/metacubex/mihomo/rules/provider"
)

// 同时下载的 rule-provider 数，和正在用的连接抢带宽时不至于太多。
const prefetchConcurrency = 4

type vehicleOwner interface {
	Vehicle() P.Vehicle
}

// prefetch 预先下载 path 里本地还没有的 rule-provider。热切换的应用阶段要等所有 provider
// 加载完，第一次切到一份带几十个规则集的配置要等几秒，期间新连接会失败（ADR-0010）。
// 下载过的文件留在原来的位置，真正切换时 Fetcher.Initial 直接读本地文件。
//
// 只处理 rule-provider：proxy-provider 的 Initial 会按节点名关掉正在用的连接，
// 正在运行的配置里有同名节点时会误伤。
func prefetch(path string) (int, error) {
	if _, ok := runningProfile(); !ok {
		return 0, errors.New("core is not running")
	}
	if err := checkProfilePath(path); err != nil {
		return 0, err
	}
	buf, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	rawCfg, err := config.UnmarshalRawConfig(buf)
	if err != nil {
		return 0, err
	}

	var downloaded atomic.Int32
	var wg sync.WaitGroup
	sem := make(chan struct{}, prefetchConcurrency)
	for name, mapping := range rawCfg.RuleProvider {
		rp, err := RP.ParseRuleProvider(name, mapping, R.ParseRule, RB.MakeBundleFile)
		if err != nil || rp.VehicleType() != P.HTTP {
			continue
		}
		owner, ok := rp.(vehicleOwner)
		if !ok {
			continue
		}
		if _, err := os.Stat(owner.Vehicle().Path()); err == nil {
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			// Initial 在本地没有文件时下载并保存，然后会启动定时更新，这里不需要，立即关掉。
			if err := rp.Initial(); err != nil {
				log.Warnln("[ArkClash] prefetch rule provider %s: %s", rp.Name(), err)
			} else {
				downloaded.Add(1)
			}
			if closer, ok := rp.(interface{ Close() error }); ok {
				_ = closer.Close()
			}
		}()
	}
	wg.Wait()
	return int(downloaded.Load()), nil
}
