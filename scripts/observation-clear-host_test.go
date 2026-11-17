package dns

import (
	"context"
	"fmt"
	"net"
	"net/netip"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/fakeip"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/component/trie"
	C "github.com/metacubex/mihomo/constant"

	D "github.com/miekg/dns"
)

type observationClearClient struct {
	resets  atomic.Int32
	queries atomic.Int32
	entered chan struct{}
	release <-chan struct{}
	once    sync.Once
}

func (c *observationClearClient) ExchangeContext(ctx context.Context, m *D.Msg) (*D.Msg, error) {
	c.queries.Add(1)
	if c.entered != nil {
		c.once.Do(func() { close(c.entered) })
		select {
		case <-c.release:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return observationClearAnswer(m), nil
}

func (*observationClearClient) Address() string { return "local-clear-client" }

func (c *observationClearClient) ResetConnection() { c.resets.Add(1) }

type observationClearNonComparableClient struct {
	*observationClearClient
	marker []byte
}

type observationClearDomain string

func (d observationClearDomain) MatchDomain(domain string) bool { return string(d) == domain }

func observationClearAnswer(m *D.Msg) *D.Msg {
	answer := new(D.Msg)
	answer.SetReply(m)
	answer.Answer = []D.RR{&D.A{
		Hdr: D.RR_Header{Name: m.Question[0].Name, Rrtype: D.TypeA, Class: D.ClassINET, Ttl: 60},
		A:   net.IPv4(127, 0, 0, 1),
	}}
	return answer
}

func observationClearQuestion(domain string) *D.Msg {
	return new(D.Msg).SetQuestion(D.Fqdn(domain), D.TypeA)
}

func observationClearFixture(t *testing.T) {
	t.Helper()
	oldDefault, oldSystem := resolver.DefaultResolver, resolver.SystemResolver
	oldProxy, oldDirect := resolver.ProxyServerHostResolver, resolver.DirectHostResolver
	oldMapper := resolver.DefaultHostMapper
	oldObserver := queryObserver.Load()
	SetQueryObserver(nil)
	t.Cleanup(func() {
		SetQueryObserver(nil)
		resolver.DefaultResolver, resolver.SystemResolver = oldDefault, oldSystem
		resolver.ProxyServerHostResolver, resolver.DirectHostResolver = oldProxy, oldDirect
		resolver.DefaultHostMapper = oldMapper
		if oldObserver != nil {
			queryObserver.Store(oldObserver)
			resolver.SetQueryObservationEnabled(true)
		}
	})
}

func TestArkClashObservationClearAllResolverGraph(t *testing.T) {
	for _, algorithm := range []string{"lru", "arc"} {
		t.Run(algorithm, func(t *testing.T) {
			observationClearFixture(t)
			q := observationClearQuestion("cached.diag.test")
			names := []string{
				"main", "proxy", "direct", "default", "nested-default",
				"system", "system-proxy", "system-direct", "system-default",
			}
			roots := make(map[string]*Resolver, len(names))
			clients := make(map[string]*observationClearClient, len(names))
			for _, name := range names {
				c := new(observationClearClient)
				r := &Resolver{main: []dnsClient{c}, cache: (Config{CacheAlgorithm: algorithm}).newCache()}
				putMsgToCache(r.cache, q.Question[0], observationClearAnswer(q))
				if _, _, hit := getMsgFromCache(r.cache, q.Question[0]); !hit {
					t.Fatalf("%s cache was not seeded", name)
				}
				roots[name], clients[name] = r, c
			}
			roots["main"].defaultResolver = roots["default"]
			roots["default"].defaultResolver = roots["nested-default"]
			roots["nested-default"].defaultResolver = roots["main"]
			roots["proxy"].defaultResolver = roots["default"]
			roots["direct"].defaultResolver = roots["default"]
			roots["system"].defaultResolver = roots["system-default"]
			roots["system-default"].defaultResolver = roots["default"]
			resolver.DefaultResolver = Resolvers{
				Resolver: roots["main"], ProxyResolver: roots["proxy"], DirectResolver: roots["direct"],
			}
			resolver.SystemResolver = Resolvers{
				Resolver: roots["system"], ProxyResolver: roots["system-proxy"], DirectResolver: roots["system-direct"],
			}
			resolver.ProxyServerHostResolver, resolver.DirectHostResolver = roots["proxy"], roots["direct"]

			fallback, trieOnly, matcherOnly := new(observationClearClient), new(observationClearClient), new(observationClearClient)
			shared := clients["main"]
			wrapped := clientWithEdns0Subnet{
				dnsClient: clientWithDisableTypes{dnsClient: shared, disableTypes: map[uint16]struct{}{D.TypeAAAA: {}}},
				ecsPrefix: netip.MustParsePrefix("192.0.2.0/24"),
			}
			policyTrie := trie.New[[]dnsClient]()
			if err := policyTrie.Insert("policy.diag.test", []dnsClient{trieOnly, wrapped}); err != nil {
				t.Fatal(err)
			}
			policyTrie.Optimize()
			roots["main"].fallback = []dnsClient{fallback, wrapped}
			roots["main"].policy = []dnsPolicy{
				domainTriePolicy{policyTrie},
				domainMatcherPolicy{matcher: observationClearDomain("matcher.diag.test"), dnsClients: []dnsClient{matcherOnly, wrapped}},
			}
			roots["proxy"].policy = roots["main"].policy
			roots["direct"].main = append(roots["direct"].main, wrapped)
			nonComparable := new(observationClearClient)
			roots["system-direct"].fallback = []dnsClient{observationClearNonComparableClient{
				observationClearClient: nonComparable, marker: []byte{1},
			}}

			SetQueryObserver(func(QueryRecord) {})
			observer := queryObserver.Load()
			observer.answeredBy.Set("cached.diag.test.", "local-clear-client")
			ClearAll()
			for _, name := range names {
				if _, _, hit := getMsgFromCache(roots[name].cache, q.Question[0]); hit {
					t.Errorf("%s cache survived ClearAll", name)
				}
				if got := clients[name].resets.Load(); got != 1 {
					t.Errorf("%s reset count = %d, want 1", name, got)
				}
			}
			for name, c := range map[string]*observationClearClient{
				"fallback": fallback, "trie-policy": trieOnly, "matcher-policy": matcherOnly, "non-comparable": nonComparable,
			} {
				if got := c.resets.Load(); got != 1 {
					t.Errorf("%s reset count = %d, want 1", name, got)
				}
			}
			if _, ok := observer.answeredBy.Get("cached.diag.test."); ok {
				t.Error("upstream attribution survived ClearAll")
			}
			if got := shared.queries.Load(); got != 0 {
				t.Errorf("ClearAll started %d DNS queries", got)
			}
		})
	}
}

func TestArkClashObservationClearAllSystemRefreshAndFakeIP(t *testing.T) {
	observationClearFixture(t)
	pool, err := fakeip.New(fakeip.Options{IPNet: netip.MustParsePrefix("198.18.0.0/24"), Size: 16})
	if err != nil {
		t.Fatal(err)
	}
	mapper := NewEnhancer(EnhancerConfig{EnhancedMode: C.DNSFakeIP, FakeIPPool: pool})
	resolver.DefaultHostMapper = mapper
	ip := pool.Lookup("retained.diag.test")
	mappedIP := netip.MustParseAddr("192.0.2.123")
	mapper.InsertHostByIP(mappedIP, "mapped.diag.test")
	system := newSystemClient()
	system.lastFlush = time.Now()
	r := NewResolverFromClient(clientWithDisableTypes{
		dnsClient: system, disableTypes: map[uint16]struct{}{D.TypeAAAA: {}},
	})
	resolver.DefaultResolver = nil
	resolver.SystemResolver = Resolvers{Resolver: r}

	ClearAll()
	system.mu.Lock()
	lastFlush := system.lastFlush
	system.mu.Unlock()
	if !lastFlush.IsZero() {
		t.Errorf("system refresh time = %s, want zero", lastFlush)
	}
	if !mapper.IsExistFakeIP(ip) {
		t.Fatal("ClearAll removed FakeIP mapping")
	}
	if host, ok := mapper.FindHostByIP(ip); !ok || host != "retained.diag.test" {
		t.Errorf("FakeIP reverse mapping = %q, %v", host, ok)
	}
	if got := pool.Lookup("retained.diag.test"); got != ip {
		t.Errorf("FakeIP changed from %s to %s", ip, got)
	}
	if host, ok := mapper.FindHostByIP(mappedIP); !ok || host != "mapped.diag.test" {
		t.Errorf("host reverse mapping = %q, %v", host, ok)
	}
	resolver.SystemResolver = Resolvers{}
	ClearAll()
}

func TestArkClashObservationClearAllConcurrentQueries(t *testing.T) {
	for _, algorithm := range []string{"lru", "arc"} {
		t.Run(algorithm, func(t *testing.T) {
			observationClearFixture(t)
			release := make(chan struct{})
			var releaseOnce sync.Once
			unblock := func() { releaseOnce.Do(func() { close(release) }) }
			defer unblock()
			c := &observationClearClient{entered: make(chan struct{}), release: release}
			r := &Resolver{main: []dnsClient{c}, cache: (Config{CacheAlgorithm: algorithm}).newCache()}
			resolver.DefaultResolver, resolver.SystemResolver = Resolvers{Resolver: r}, nil
			SetQueryObserver(func(QueryRecord) {})
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			q := observationClearQuestion("inflight.diag.test")
			finished := make(chan error, 1)
			go func() {
				_, err := r.ExchangeContext(ctx, q)
				finished <- err
			}()
			select {
			case <-c.entered:
			case <-ctx.Done():
				t.Fatal("query did not reach local DNS client")
			}
			ClearAll()
			if got := c.resets.Load(); got != 1 {
				t.Fatalf("in-flight client reset count = %d, want 1", got)
			}
			unblock()
			select {
			case err := <-finished:
				if err != nil {
					t.Fatal(err)
				}
			case <-ctx.Done():
				t.Fatal("ClearAll interrupted the in-flight query")
			}
			if _, _, hit := getMsgFromCache(r.cache, q.Question[0]); !hit {
				t.Fatal("completed in-flight query did not refill cache")
			}

			start := make(chan struct{})
			var workers sync.WaitGroup
			for worker := 0; worker < 3; worker++ {
				workers.Add(1)
				go func(worker int) {
					defer workers.Done()
					<-start
					for i := 0; i < 64; i++ {
						m := observationClearQuestion(fmt.Sprintf("%d-%d.concurrent.diag.test", worker, i))
						answer, err := r.ExchangeContext(ctx, m)
						if err != nil || answer == nil || len(answer.Answer) != 1 {
							t.Errorf("concurrent query = %v, %v", answer, err)
							return
						}
					}
				}(worker)
			}
			workers.Add(1)
			go func() {
				defer workers.Done()
				<-start
				for i := 0; i < 64; i++ {
					ClearAll()
				}
			}()
			close(start)
			workers.Wait()
			if got := c.resets.Load(); got != 65 {
				t.Errorf("concurrent reset count = %d, want 65", got)
			}
			ClearAll()
			if _, _, hit := getMsgFromCache(r.cache, q.Question[0]); hit {
				t.Error("quiescent cache survived ClearAll")
			}
		})
	}
}
