package dns

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/fakeip"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/component/trie"
	D "github.com/miekg/dns"
)

type arkObservationClient struct {
	exchange func(context.Context, *D.Msg) (*D.Msg, error)
	calls atomic.Int32
}

func (c *arkObservationClient) Address() string { return "tcp://127.0.0.1:15353" }
func (c *arkObservationClient) ResetConnection() {}
func (c *arkObservationClient) ExchangeContext(ctx context.Context, msg *D.Msg) (*D.Msg, error) {
	c.calls.Add(1)
	if c.exchange != nil {
		return c.exchange(ctx, msg)
	}
	return arkObservationReply(msg), nil
}

func arkObservationReply(msg *D.Msg) *D.Msg {
	reply := new(D.Msg)
	reply.SetReply(msg)
	q := msg.Question[0]
	hdr := D.RR_Header{Name: q.Name, Rrtype: q.Qtype, Class: D.ClassINET, Ttl: 60}
	switch q.Qtype {
	case D.TypeA:
		reply.Answer = []D.RR{&D.A{Hdr: hdr, A: net.ParseIP("192.0.2.7").To4()}}
	case D.TypeAAAA:
		reply.Answer = []D.RR{&D.AAAA{Hdr: hdr, AAAA: net.ParseIP("2001:db8::7")}}
	case D.TypeCNAME:
		reply.Answer = []D.RR{&D.CNAME{Hdr: hdr, Target: "target.diag.test."}}
	}
	return reply
}

func arkObservationQuestion(name string, qtype uint16) *D.Msg {
	return new(D.Msg).SetQuestion(name, qtype)
}

func arkObservationResolver(client dnsClient) *Resolver {
	return &Resolver{main: []dnsClient{client}, cache: Config{}.newCache(), ipv6: true}
}

func arkObservationRecords(t *testing.T) func() []QueryRecord {
	t.Helper()
	var mu sync.Mutex
	var records []QueryRecord
	SetQueryObserver(func(record QueryRecord) {
		if record.Msg != nil {
			record.Msg = record.Msg.Copy()
		}
		mu.Lock()
		records = append(records, record)
		mu.Unlock()
	})
	t.Cleanup(func() { SetQueryObserver(nil) })
	return func() []QueryRecord {
		mu.Lock()
		defer mu.Unlock()
		return append([]QueryRecord(nil), records...)
	}
}

func arkObservationReceive[T any](t *testing.T, ch <-chan T) T {
	t.Helper()
	select {
	case value := <-ch:
		return value
	case <-time.After(5 * time.Second):
		t.Fatal("DNS observation fixture timed out")
		var zero T
		return zero
	}
}

func TestArkClashObservationDnsMissHitAndInitiators(t *testing.T) {
	records := arkObservationRecords(t)
	client := &arkObservationClient{}
	r := arkObservationResolver(client)
	for _, initiator := range []string{resolver.InitiatorRule, resolver.InitiatorDirect, resolver.InitiatorProxy, resolver.InitiatorOther} {
		ctx := resolver.WithInitiator(context.Background(), initiator)
		q := arkObservationQuestion(initiator+".diag.test.", D.TypeA)
		before := time.Now()
		if _, err := r.ExchangeContext(ctx, q); err != nil { t.Fatal(err) }
		hitStart := time.Now()
		if _, err := r.ExchangeContext(ctx, q); err != nil { t.Fatal(err) }
		got := records()
		miss, hit := got[len(got)-2], got[len(got)-1]
		if miss.Cached || !hit.Cached || miss.Initiator != initiator || hit.Initiator != initiator || miss.Upstream != client.Address() || hit.Upstream != client.Address() {
			t.Fatalf("incorrect miss/hit attribution: %+v / %+v", miss, hit)
		}
		if miss.Start.Before(before) || hit.Start.Before(hitStart) { t.Fatal("cache hit reused original exchange time") }
	}
	service := &Service{handler: withResolver(r, true)}
	if _, err := service.ServeMsg(context.Background(), arkObservationQuestion("app.diag.test.", D.TypeA)); err != nil { t.Fatal(err) }
	if _, err := r.ExchangeContext(context.Background(), arkObservationQuestion("other.diag.test.", D.TypeAAAA)); err != nil { t.Fatal(err) }
	got := records()
	if len(got) != 10 || got[8].Initiator != resolver.InitiatorApp || got[9].Initiator != resolver.InitiatorOther || client.calls.Load() != 6 {
		t.Fatalf("incorrect app/default classification or cache behavior: %+v calls=%d", got, client.calls.Load())
	}
}

func TestArkClashObservationDnsAnswersAndErrors(t *testing.T) {
	records := arkObservationRecords(t)
	client := &arkObservationClient{}
	r := arkObservationResolver(client)
	for _, qtype := range []uint16{D.TypeAAAA, D.TypeCNAME} {
		q := arkObservationQuestion("answer.diag.test.", qtype)
		if _, err := r.ExchangeContext(context.Background(), q); err != nil { t.Fatal(err) }
		got := records()
		record := got[len(got)-1]
		if record.Msg == nil || len(record.Msg.Answer) != 1 || record.Msg.Answer[0].Header().Rrtype != qtype || record.Question.Qtype != qtype { t.Fatalf("answer lost: %+v", record) }
	}
	client.exchange = func(_ context.Context, q *D.Msg) (*D.Msg, error) {
		reply := new(D.Msg)
		reply.SetRcode(q, D.RcodeNameError)
		return reply, nil
	}
	if _, err := r.ExchangeContext(context.Background(), arkObservationQuestion("missing.diag.test.", D.TypeA)); err != nil { t.Fatal(err) }
	got := records()
	if record := got[len(got)-1]; record.Err != nil || record.Msg.Rcode != D.RcodeNameError || record.Upstream != client.Address() { t.Fatalf("NXDOMAIN lost: %+v", record) }
	client.exchange = func(context.Context, *D.Msg) (*D.Msg, error) { return nil, errors.New("fixture unreachable") }
	ctx, release := resolver.WithRequestContext(context.Background())
	defer release()
	if _, err := r.ExchangeContext(ctx, arkObservationQuestion("failure.diag.test.", D.TypeA)); err == nil { t.Fatal("expected exchange failure") }
	got = records()
	if record := got[len(got)-1]; record.Err == nil || record.Upstream != "" || record.Msg != nil { t.Fatalf("failure fabricated answer/upstream: %+v", record) }
}

func TestArkClashObservationDnsDisabledAndUnknownCache(t *testing.T) {
	SetQueryObserver(nil)
	t.Cleanup(func() { SetQueryObserver(nil) })
	ctx := context.Background()
	if got := resolver.WithInitiator(ctx, resolver.InitiatorRule); got != ctx { t.Fatal("disabled classification wrapped context") }
	if allocs := testing.AllocsPerRun(100, func() { _ = resolver.WithInitiator(ctx, resolver.InitiatorDirect) }); allocs != 0 { t.Fatalf("disabled classification allocates %v", allocs) }
	client := &arkObservationClient{}
	r := arkObservationResolver(client)
	q := arkObservationQuestion("hidden.diag.test.", D.TypeA)
	if _, err := r.ExchangeContext(ctx, q); err != nil { t.Fatal(err) }
	if queryObserver.Load() != nil { t.Fatal("disabled exchange created observer") }
	if traceCtx, trace := r.traceExchange(ctx, q.Question[0], "", nil); traceCtx != ctx || trace != nil { t.Fatal("disabled exchange created trace") }
	records := arkObservationRecords(t)
	if _, err := r.ExchangeContext(ctx, q); err != nil { t.Fatal(err) }
	got := records()
	if len(got) != 1 || !got[0].Cached || got[0].Upstream != "" || client.calls.Load() != 1 { t.Fatalf("hidden upstream fabricated: %+v", got) }
}

func TestArkClashObservationDnsRetiredTraceAndCancellation(t *testing.T) {
	records := arkObservationRecords(t)
	entered := make(chan context.Context, 1)
	release := make(chan struct{})
	client := &arkObservationClient{exchange: func(ctx context.Context, q *D.Msg) (*D.Msg, error) {
		entered <- ctx
		<-release
		return arkObservationReply(q), nil
	}}
	r := arkObservationResolver(client)
	q := arkObservationQuestion("retired.diag.test.", D.TypeA)
	finished := make(chan error, 1)
	go func() { _, err := r.ExchangeContext(context.Background(), q); finished <- err }()
	queryCtx := arkObservationReceive(t, entered)
	old := queryObserver.Load()
	oldTrace, _ := queryCtx.Value(exchangeTraceKey{}).(*exchangeTrace)
	if oldTrace == nil { t.Fatal("actual exchange did not carry trace") }
	SetQueryObserver(nil)
	select { case <-queryCtx.Done(): t.Fatal("observer stop canceled business DNS"); default: }
	newRecords := arkObservationRecords(t)
	newObserver := queryObserver.Load()
	late := arkObservationReply(q)
	traceAnswer(queryCtx, late, "retired-upstream")
	oldTrace.mu.Lock()
	_, retained := oldTrace.upstreams[late]
	oldTrace.mu.Unlock()
	if retained { t.Fatal("retired trace retained late answer") }
	close(release)
	if err := arkObservationReceive(t, finished); err != nil { t.Fatal(err) }
	if len(records()) != 0 || len(newRecords()) != 0 { t.Fatal("retired exchange notified old/new subscription") }
	for _, observer := range []*queryObservation{old, newObserver} {
		if _, ok := observer.answeredBy.Get(answeredByKey(r, q.Question[0])); ok { t.Fatal("retired exchange updated attribution cache") }
	}
	if _, err := r.ExchangeContext(context.Background(), q); err != nil { t.Fatal(err) }
	if got := newRecords(); len(got) != 1 || !got[0].Cached || got[0].Upstream != "" { t.Fatalf("retired answer leaked new attribution: %+v", got) }
}

type arkObservationSelectedContext struct {
	context.Context
	selected chan struct{}
	once sync.Once
}

func (ctx *arkObservationSelectedContext) Done() <-chan struct{} {
	ctx.once.Do(func() { close(ctx.selected) })
	return nil
}

func TestArkClashObservationDnsSingleflight(t *testing.T) {
	records := arkObservationRecords(t)
	entered := make(chan struct{}, 2)
	release := make(chan struct{})
	client := &arkObservationClient{exchange: func(_ context.Context, q *D.Msg) (*D.Msg, error) {
		entered <- struct{}{}
		<-release
		return arkObservationReply(q), nil
	}}
	r := arkObservationResolver(client)
	q := arkObservationQuestion("shared.diag.test.", D.TypeA)
	finished := make(chan error, 2)
	go func() { _, err := r.ExchangeContext(context.Background(), q.Copy()); finished <- err }()
	arkObservationReceive(t, entered)
	second := &arkObservationSelectedContext{Context: context.Background(), selected: make(chan struct{})}
	go func() { _, err := r.ExchangeContext(second, q.Copy()); finished <- err }()
	arkObservationReceive(t, second.selected)
	close(release)
	for i := 0; i < 2; i++ { if err := arkObservationReceive(t, finished); err != nil { t.Fatal(err) } }
	if got := records(); len(got) != 1 || got[0].Cached || client.calls.Load() != 1 { t.Fatalf("singleflight produced duplicate traces: %+v calls=%d", got, client.calls.Load()) }
}

func TestArkClashObservationDnsHostsAndFakeIPExcluded(t *testing.T) {
	records := arkObservationRecords(t)
	oldHosts := resolver.DefaultHosts
	resolver.DefaultHosts = resolver.NewHosts(trie.New[resolver.HostValue]())
	t.Cleanup(func() { resolver.DefaultHosts = oldHosts })
	host, err := resolver.NewHostValue([]string{"192.0.2.9"})
	if err != nil { t.Fatal(err) }
	if err := resolver.DefaultHosts.Insert("hosts.diag.test", host); err != nil { t.Fatal(err) }
	pool, err := fakeip.New(fakeip.Options{IPNet: netip.MustParsePrefix("198.18.0.0/24"), Size: 16})
	if err != nil { t.Fatal(err) }
	client := &arkObservationClient{}
	r := arkObservationResolver(client)
	services := []*Service{
		{handler: withHosts(nil)(withResolver(r, true))},
		{handler: withFakeIP(&fakeip.Skipper{}, pool, nil, 60)(withResolver(r, true))},
	}
	for i, name := range []string{"hosts.diag.test.", "fake.diag.test."} {
		answer, err := services[i].ServeMsg(context.Background(), arkObservationQuestion(name, D.TypeA))
		if err != nil || answer == nil || len(answer.Answer) != 1 { t.Fatalf("middleware did not answer %s: %v %v", name, answer, err) }
	}
	if got := records(); len(got) != 0 || client.calls.Load() != 0 { t.Fatalf("hosts/fakeIP created records: %+v", got) }
}

func TestArkClashObservationDnsRequestContextCancellation(t *testing.T) {
	_ = arkObservationRecords(t)
	entered := make(chan struct{}, 1)
	client := &arkObservationClient{exchange: func(ctx context.Context, _ *D.Msg) (*D.Msg, error) {
		entered <- struct{}{}
		<-ctx.Done()
		return nil, ctx.Err()
	}}
	r := arkObservationResolver(client)
	parent, cancel := context.WithCancel(context.Background())
	ctx, release := resolver.WithRequestContext(parent)
	defer release()
	ctx = resolver.WithInitiator(ctx, resolver.InitiatorRule)
	finished := make(chan error, 1)
	go func() { _, err := r.ExchangeContext(ctx, arkObservationQuestion("cancel.diag.test.", D.TypeA)); finished <- err }()
	arkObservationReceive(t, entered)
	cancel()
	if err := arkObservationReceive(t, finished); err == nil { t.Fatal("request cancellation was lost") }
}

func TestArkClashObservationDnsAttributionBoundAndConcurrentRetirement(t *testing.T) {
	_ = arkObservationRecords(t)
	r := arkObservationResolver(&arkObservationClient{})
	observer := queryObserver.Load()
	first := D.Question{Name: "first.diag.test.", Qtype: D.TypeA, Qclass: D.ClassINET}
	ctx, trace := r.traceExchange(context.Background(), first, resolver.InitiatorOther, observer)
	answer := arkObservationReply(&D.Msg{Question: []D.Question{first}})
	traceAnswer(ctx, answer, "fixture-upstream")
	trace.finish(answer, nil)
	for i := 0; i < 4096; i++ {
		q := D.Question{Name: netip.AddrFrom4([4]byte{192, 0, byte(i >> 8), byte(i)}).String() + ".diag.test.", Qtype: D.TypeA, Qclass: D.ClassINET}
		ctx, trace := r.traceExchange(context.Background(), q, resolver.InitiatorOther, observer)
		answer := arkObservationReply(&D.Msg{Question: []D.Question{q}})
		traceAnswer(ctx, answer, "fixture-upstream")
		trace.finish(answer, nil)
	}
	if _, ok := observer.answeredBy.Get(answeredByKey(r, first)); ok { t.Fatal("attribution exceeded 4096 entry limit") }
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for n := 0; n < 20; n++ {
				ctx, trace := r.traceExchange(context.Background(), first, resolver.InitiatorOther, observer)
				traceAnswer(ctx, answer, "late-upstream")
				trace.finish(answer, nil)
			}
		}()
	}
	SetQueryObserver(nil)
	wg.Wait()
	if queryObserver.Load() != nil { t.Fatal("retirement left observer published") }
}
