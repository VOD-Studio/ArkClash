package statistic

import (
	"errors"
	"sync"
	"testing"

	C "github.com/metacubex/mihomo/constant"
)

type observationTCP struct {
	C.Conn
	closed bool
}

func (c *observationTCP) Close() error { c.closed = true; return errors.New("closed") }
func (c *observationTCP) RemoteDestination() string { return "" }
func (c *observationTCP) Chains() C.Chain { return C.Chain{"DIRECT"} }
func (c *observationTCP) ProviderChains() C.Chain { return nil }

type observationUDP struct {
	C.PacketConn
	closed bool
}

func (c *observationUDP) Close() error { c.closed = true; return nil }
func (c *observationUDP) RemoteDestination() string { return "" }
func (c *observationUDP) Chains() C.Chain { return C.Chain{"DIRECT"} }
func (c *observationUDP) ProviderChains() C.Chain { return nil }

func TestArkClashObservationJoinBeforeStore(t *testing.T) {
	defer SetTrackerObserver(nil)
	manager := new(Manager)
	entered, release, joined := make(chan Tracker, 1), make(chan struct{}), make(chan Tracker, 1)
	SetTrackerObserver(&TrackerObserver{Open: func(tracker Tracker) {
		entered <- tracker
		<-release
	}})
	go func() { joined <- NewTCPTracker(&observationTCP{}, manager, &C.Metadata{}, nil, 0, 0, false) }()
	tracker := <-entered
	if manager.Get(tracker.ID()) != nil { t.Fatal("Join stored before Open") }
	count := 0
	manager.Range(func(Tracker) bool { count++; return true })
	if count != 0 { t.Fatal("initial Range saw blocked Join") }
	close(release)
	if got := <-joined; manager.Get(got.ID()) != got { t.Fatal("Join failed to publish tracker") }
}

func TestArkClashObservationCloseAfterUnderlyingClose(t *testing.T) {
	defer SetTrackerObserver(nil)
	manager := new(Manager)
	tcp, udp := &observationTCP{}, &observationUDP{}
	opened, closed := 0, 0
	SetTrackerObserver(&TrackerObserver{Open: func(Tracker) { opened++ }, Close: func(tracker Tracker) {
		closed++
		if manager.Get(tracker.ID()) != nil { t.Fatal("Close notified before Leave") }
		switch tracker.(type) {
		case *tcpTracker: if !tcp.closed { t.Fatal("TCP not closed before notification") }
		case *udpTracker: if !udp.closed { t.Fatal("UDP not closed before notification") }
		}
	}})
	tt := NewTCPTracker(tcp, manager, &C.Metadata{}, nil, 0, 0, false)
	ut := NewUDPTracker(udp, manager, &C.Metadata{}, nil, 0, 0, false)
	if tt.Close() == nil { t.Fatal("lost underlying TCP error") }
	if ut.Close() != nil { t.Fatal("unexpected UDP error") }
	if opened != 2 || closed != 2 { t.Fatalf("open=%d close=%d", opened, closed) }
	SetTrackerObserver(nil)
	_ = tt.Close()
	if closed != 2 { t.Fatal("disabled observer received Close") }
}

func TestArkClashObservationConcurrentObserverPublication(t *testing.T) {
	defer SetTrackerObserver(nil)
	var workers sync.WaitGroup
	for i := 0; i < 4; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			manager := new(Manager)
			for n := 0; n < 100; n++ {
				SetTrackerObserver(&TrackerObserver{Open: func(Tracker) {}, Close: func(Tracker) {}})
				tracker := NewTCPTracker(&observationTCP{}, manager, &C.Metadata{}, nil, 0, 0, false)
				_ = tracker.Close()
				SetTrackerObserver(nil)
			}
		}()
	}
	workers.Wait()
}
