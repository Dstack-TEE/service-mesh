package main

import (
	"context"
	"fmt"
	"log"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// =============================================================================
// Tests use the production snapshot broker, not a second implementation.
// =============================================================================

type testBroker struct {
	server *httptest.Server
	broker *signalBroker
}

var testSignalKey = make([]byte, 32)

func newTestBroker() *testBroker {
	cfg := &Config{ClusterName: "test", SignalingKey: testSignalKey, Peers: twoPeers()}
	b := &testBroker{broker: newSignalBroker(cfg)}
	b.server = httptest.NewServer(b.broker)
	return b
}
func (b *testBroker) URL() string { return b.server.URL }
func (b *testBroker) Close()      { b.server.Close() }

// =============================================================================
// Test-peer factory: build a Mesh with onLinkUp hook + capture goroutines.
// =============================================================================

type testPeer struct {
	id             string
	mesh           *Mesh
	cancel         context.CancelFunc
	linkUp         chan string // peer-ID of the OTHER side, sent once per "link up"
	attemptStarted chan string // peer-ID of the OTHER side, sent every time consumedAuth gets set
	done           chan struct{}
	logPrefix      string
}

// newTestPeer builds a Mesh for one side. peers is the full PEERS_JSON
// (every peer including self), selfID picks which one this Mesh is.
// allowlistPort is a single TCP-only allowlist entry; tests bind real
// listeners on 127.50.0.<peer.vip>:port, which is harmless on Linux
// (the whole 127.0.0.0/8 is loopback). Pass distinct ports across
// concurrent tests so two harnesses don't conflict.
func newTestPeer(t *testing.T, brokerURL, selfID string, peers []Peer, allowlistPort int) *testPeer {
	t.Helper()
	cfg := &Config{
		SelfID:        selfID,
		Peers:         peers,
		SignalingURLs: []string{brokerURL},
		ClusterName:   "test",
		SignalingKey:  testSignalKey,
		Allowlist:     []InfraPort{{Port: allowlistPort, UDP: false}},
		// No STUN URLs — ICE will use host candidates only, which is
		// what we want for a loopback test.
	}
	if err := validateConfig(cfg); err != nil {
		t.Fatalf("bad test config for %s: %v", selfID, err)
	}
	m := newMesh(cfg)
	tp := &testPeer{
		id:             selfID,
		mesh:           m,
		linkUp:         make(chan string, 64),
		attemptStarted: make(chan string, 64),
		done:           make(chan struct{}),
		logPrefix:      "[" + selfID + "] ",
	}
	m.onLinkUp = func(peerID string) {
		select {
		case tp.linkUp <- peerID:
		default:
		}
	}
	m.onAttemptStarted = func(peerID string) {
		select {
		case tp.attemptStarted <- peerID:
		default:
		}
	}
	return tp
}

func (tp *testPeer) start(ctx context.Context) {
	ctx, cancel := context.WithCancel(ctx)
	tp.cancel = cancel
	go func() {
		defer close(tp.done)
		tp.mesh.Run(ctx)
	}()
}

func (tp *testPeer) stop() {
	if tp.cancel != nil {
		tp.cancel()
	}
	select {
	case <-tp.done:
	case <-time.After(15 * time.Second):
		// don't block test cleanup forever; pion goroutines may take
		// a moment to wind down after agent.Close.
	}
}

// =============================================================================
// Log capture: route the standard logger into a per-test buffer so we
// can grep for diagnostic strings (e.g. "supersedes") and surface them
// on failure without flooding the test output on success.
// =============================================================================

type testLogSink struct {
	t   *testing.T
	mu  sync.Mutex
	buf strings.Builder
}

func (s *testLogSink) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.buf.Write(p)
	return len(p), nil
}

func (s *testLogSink) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.String()
}

func (s *testLogSink) countLines(needle string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return strings.Count(s.buf.String(), needle)
}

// captureLogs redirects the default logger to a sink for the duration
// of the test. Restored in cleanup. Note: log package is global, so
// tests using this can't run in parallel — they don't, we don't pass
// t.Parallel() in any of the harness tests.
func captureLogs(t *testing.T) *testLogSink {
	t.Helper()
	sink := &testLogSink{t: t}
	prev := log.Writer()
	log.SetOutput(sink)
	t.Cleanup(func() {
		log.SetOutput(prev)
	})
	return sink
}

// =============================================================================
// waitBothLinksUp blocks until both peers see their counterpart come up,
// or deadline expires. Returns the time it took, or an error explaining
// what was still pending.
// =============================================================================

func waitBothLinksUp(t *testing.T, a, b *testPeer, deadline time.Duration) (time.Duration, error) {
	t.Helper()
	start := time.Now()
	aUp := false
	bUp := false
	timeout := time.After(deadline)
	for !(aUp && bUp) {
		select {
		case peerID := <-a.linkUp:
			if peerID == b.id {
				aUp = true
			}
		case peerID := <-b.linkUp:
			if peerID == a.id {
				bUp = true
			}
		case <-timeout:
			return time.Since(start),
				fmt.Errorf("link-up deadline exceeded: %s↔%s aUp=%v bUp=%v",
					a.id, b.id, aUp, bUp)
		}
	}
	return time.Since(start), nil
}

// =============================================================================
// Shared peer-pair / port plan for the harness tests. peer-A < peer-B
// lex, so peer-A is the controlling (Dial) side; this matches how
// mesh-conn picks Dial vs Accept everywhere else (cfg.SelfID < remoteID).
// =============================================================================

func twoPeers() []Peer {
	return []Peer{
		{ID: "peer-A", Vip: 1},
		{ID: "peer-B", Vip: 2},
	}
}
