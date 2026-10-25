package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/pion/ice/v2"
)

func signalTestConfig(peer string) *Config {
	return &Config{SelfID: peer, ClusterName: "test", SignalingKey: testSignalKey, Peers: twoPeers()}
}

func signalTestAuth(label string) [2]string {
	return [2]string{label + "-ufrag", label + "-password-01234567890123456789"}
}

func syncSignals(t *testing.T, client *signalClient, endpoint string) []signalRecord {
	t.Helper()
	records, err := client.exchange(context.Background(), endpoint)
	if err != nil {
		t.Fatal(err)
	}
	return records
}

func TestSignalSnapshotsAreNotDrainedAndExpire(t *testing.T) {
	b := newTestBroker()
	defer b.Close()
	now := time.Now()
	b.broker.now = func() time.Time { return now }
	a := newSignalClient(signalTestConfig("peer-A"))
	a.setAuth("peer-B", signalTestAuth("first"))
	syncSignals(t, a, b.URL())
	receiver := newSignalClient(signalTestConfig("peer-B"))
	for i := 0; i < 2; i++ {
		r := syncSignals(t, receiver, b.URL())
		if len(r) != 1 || r[0].Auth != signalTestAuth("first") {
			t.Fatalf("poll %d: %+v", i, r)
		}
	}
	now = now.Add(signalLease + time.Second)
	if r := syncSignals(t, receiver, b.URL()); len(r) != 0 {
		t.Fatalf("expired records: %+v", r)
	}
}

func TestSignalRejectsDuplicatesAndOldVersions(t *testing.T) {
	a := newSignalClient(signalTestConfig("peer-A"))
	a.setAuth("peer-B", signalTestAuth("first"))
	old := a.snapshot().Records[0]
	a.setAuth("peer-B", signalTestAuth("second"))
	current := a.snapshot().Records[0]
	b := newSignalClient(signalTestConfig("peer-B"))
	var delivered []signalRecord
	deliver := func(r signalRecord) { delivered = append(delivered, r) }
	b.accept([]signalRecord{current, current, old}, deliver)
	if len(delivered) != 1 || delivered[0].Auth != current.Auth {
		t.Fatalf("deliveries: %+v", delivered)
	}
	if b.snapshot().Records == nil {
		t.Fatal("nil snapshot")
	}
	if b.clock <= current.Clock {
		t.Fatal("Lamport receive rule not applied")
	}
}

func TestSignalBrokerRejectsReorderedWrites(t *testing.T) {
	b := newTestBroker()
	defer b.Close()
	a := newSignalClient(signalTestConfig("peer-A"))
	a.setAuth("peer-B", signalTestAuth("old"))
	old := a.snapshot()
	a.setAuth("peer-B", signalTestAuth("new"))
	current := a.snapshot()
	if code := signalRequest(b.broker, a.cfg, current); code != 200 {
		t.Fatal(code)
	}
	if code := signalRequest(b.broker, a.cfg, old); code != 200 {
		t.Fatal(code)
	}
	r := syncSignals(t, newSignalClient(signalTestConfig("peer-B")), b.URL())
	if len(r) != 1 || r[0].Auth != signalTestAuth("new") {
		t.Fatalf("stale write won: %+v", r)
	}
}

func TestSignalRestartRecoversClock(t *testing.T) {
	for _, loseBrokerState := range []bool{false, true} {
		t.Run(map[bool]string{false: "retained-broker", true: "empty-broker"}[loseBrokerState], func(t *testing.T) {
			broker := newTestBroker()
			defer broker.Close()
			a := newSignalClient(signalTestConfig("peer-A"))
			a.clock = 1000000
			a.setAuth("peer-B", signalTestAuth("old"))
			old := syncSignals(t, a, broker.URL())[0]
			b := newSignalClient(signalTestConfig("peer-B"))
			b.accept([]signalRecord{old}, func(signalRecord) {})
			if loseBrokerState {
				broker.broker.mu.Lock()
				clear(broker.broker.records)
				broker.broker.mu.Unlock()
			}
			b.setAuth("peer-A", signalTestAuth("survivor"))
			syncSignals(t, b, broker.URL())
			restarted := newSignalClient(signalTestConfig("peer-A"))
			restarted.setAuth("peer-B", signalTestAuth("restarted"))
			restarted.accept(syncSignals(t, restarted, broker.URL()), func(signalRecord) {})
			syncSignals(t, restarted, broker.URL())
			var fresh bool
			b.accept(syncSignals(t, b, broker.URL()), func(r signalRecord) { fresh = r.Auth == signalTestAuth("restarted") })
			if !fresh {
				t.Fatal("restart failed to supersede old incarnation")
			}
		})
	}
}

func signalRequest(handler http.Handler, cfg *Config, exchange signalExchange) int {
	data, _ := json.Marshal(exchange)
	req := httptest.NewRequest(http.MethodPost, "http://broker/v1/sync", bytes.NewReader(data))
	req.Header.Set("X-Mesh-Peer", cfg.SelfID)
	req.Header.Set("Authorization", "Bearer "+signalToken(cfg.SignalingKey, cfg.ClusterName, cfg.SelfID))
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)
	return w.Code
}

func TestSignalAuthenticationAndBounds(t *testing.T) {
	for _, test := range []struct {
		name   string
		mutate func(*Config, *signalExchange)
		status int
	}{
		{"wrong-key", func(c *Config, _ *signalExchange) { c.SignalingKey = bytes.Repeat([]byte{1}, 32) }, 401},
		{"wrong-cluster", func(c *Config, _ *signalExchange) { c.ClusterName = "other" }, 401},
		{"unknown-peer", func(c *Config, _ *signalExchange) { c.SelfID = "intruder" }, 401},
		{"wrong-sender", func(_ *Config, e *signalExchange) { e.Records[0].From = "peer-B" }, 400},
		{"unknown-recipient", func(_ *Config, e *signalExchange) { e.Records[0].To = "other" }, 400},
		{"duplicate-pair", func(_ *Config, e *signalExchange) { e.Records = append(e.Records, e.Records[0]) }, 400},
		{"tampered-record", func(_ *Config, e *signalExchange) { e.Records[0].Auth = signalTestAuth("tampered") }, 400},
		{"invalid-clock", func(_ *Config, e *signalExchange) { e.Records[0].Clock = 0 }, 400},
		{"invalid-candidate", func(_ *Config, e *signalExchange) {
			e.Records[0].Candidates = []string{"bad"}
			resignTestRecord(&e.Records[0])
		}, 400},
		{"relay-candidate", func(_ *Config, e *signalExchange) {
			e.Records[0].Candidates = []string{"1 1 udp 2130706431 127.0.0.1 5000 typ relay raddr 127.0.0.1 rport 5000"}
			resignTestRecord(&e.Records[0])
		}, 400},
		{"too-many-candidates", func(_ *Config, e *signalExchange) {
			e.Records[0].Candidates = make([]string, signalMaxCandidates+1)
			resignTestRecord(&e.Records[0])
		}, 400},
	} {
		t.Run(test.name, func(t *testing.T) {
			cfg := signalTestConfig("peer-A")
			broker := newSignalBroker(cfg)
			client := newSignalClient(cfg)
			client.setAuth("peer-B", signalTestAuth("valid"))
			exchange := client.snapshot()
			test.mutate(cfg, &exchange)
			if got := signalRequest(broker, cfg, exchange); got != test.status {
				t.Fatalf("got %d want %d", got, test.status)
			}
			if len(broker.records) != 0 {
				t.Fatal("invalid request mutated store")
			}
		})
	}
	broker := newSignalBroker(signalTestConfig("peer-A"))
	for i := 0; i < 20; i++ {
		if got := signalRequest(broker, signalTestConfig("peer-A"), signalExchange{Peer: "peer-A"}); got != 200 {
			t.Fatal(got)
		}
	}
	if got := signalRequest(broker, signalTestConfig("peer-A"), signalExchange{Peer: "peer-A"}); got != 429 {
		t.Fatalf("rate limit: %d", got)
	}
}

func resignTestRecord(r *signalRecord) {
	r.MAC = r.signature(signalSigningKey(testSignalKey, "test", r.From))
}

func TestAccessTokenCannotSignSnapshots(t *testing.T) {
	cfg := signalTestConfig("peer-A")
	client := newSignalClient(cfg)
	client.setAuth("peer-B", signalTestAuth("legitimate"))
	record := client.snapshot().Records[0]
	record.Auth = signalTestAuth("forged")
	record.Offer = record.Auth[0]
	record.MAC = record.signature(signalToken(cfg.SignalingKey, cfg.ClusterName, cfg.SelfID))
	if got := signalRequest(newSignalBroker(cfg), cfg, signalExchange{Peer: cfg.SelfID, Records: []signalRecord{record}}); got != 400 {
		t.Fatal(got)
	}
}

func TestSnapshotDuplicatesDoNotResetICEState(t *testing.T) {
	m := newMesh(signalTestConfig("peer-B"))
	sess := m.setupPeerSession("peer-A")
	candidate := "1 1 udp 2130706431 127.0.0.1 5000 typ host"
	r := signalRecord{From: "peer-A", To: "peer-B", Auth: signalTestAuth("same"), Candidates: []string{candidate, candidate}}
	r.Offer = r.Auth[0]
	m.applySignalRecord(r)
	m.applySignalRecord(r)
	if len(sess.candidateBuffer) != 1 || len(sess.candidateSet) != 1 {
		t.Fatal("duplicates grew candidate state")
	}
	r.Auth = signalTestAuth("next")
	r.Offer = r.Auth[0]
	r.Candidates = nil
	m.applySignalRecord(r)
	if len(sess.candidateBuffer) != 0 {
		t.Fatal("retired attempt candidates leaked")
	}
}

func TestOldAgentCannotPublishCandidates(t *testing.T) {
	a := newSignalClient(signalTestConfig("peer-A"))
	a.setAuth("peer-B", signalTestAuth("old"))
	a.setAuth("peer-B", signalTestAuth("new"))
	a.addCandidate("peer-B", signalTestAuth("old"), "old candidate")
	if len(a.snapshot().Records[0].Candidates) != 0 {
		t.Fatal("retired agent changed current snapshot")
	}
}

func TestLeaderlessColdStartWithOnlyOneWorkingBroker(t *testing.T) {
	sink := captureLogs(t)
	broker := newTestBroker()
	defer broker.Close()
	releaseSlow := make(chan struct{})
	slow := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
		case <-releaseSlow:
		}
	}))
	defer func() { close(releaseSlow); slow.Close() }()
	dead := httptest.NewServer(http.NotFoundHandler())
	deadURL := dead.URL
	dead.Close()
	a := newTestPeer(t, broker.URL(), "peer-A", twoPeers(), 21010)
	b := newTestPeer(t, broker.URL(), "peer-B", twoPeers(), 21010)
	a.mesh.cfg.SignalingURLs = []string{slow.URL, deadURL, broker.URL()}
	b.mesh.cfg.SignalingURLs = []string{broker.URL(), deadURL, slow.URL}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	a.start(ctx)
	b.start(ctx)
	defer a.stop()
	defer b.stop()
	if _, err := waitBothLinksUp(t, a, b, 10*time.Second); err != nil {
		t.Fatalf("%v\n%s", err, sink.String())
	}
	// Losing every broker must not tear down established direct connections.
	broker.Close()
	if !sleepCtx(ctx, 2*signalRefresh) {
		t.Fatal("cancelled")
	}
	for _, p := range []*testPeer{a, b} {
		sess := p.mesh.currentSession(map[string]string{"peer-A": "peer-B", "peer-B": "peer-A"}[p.id])
		sess.mu.Lock()
		up := sess.linkUp
		sess.mu.Unlock()
		if !up || len(p.linkUp) != 0 {
			t.Fatal("broker loss disrupted established link")
		}
	}
}

func TestLeaderlessRecoversWhenAllBrokersWereUnavailable(t *testing.T) {
	sink := captureLogs(t)
	var available atomic.Bool
	broker := newSignalBroker(signalTestConfig("peer-A"))
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !available.Load() {
			http.Error(w, "offline", 503)
			return
		}
		broker.ServeHTTP(w, r)
	}))
	defer server.Close()
	a := newTestPeer(t, server.URL, "peer-A", twoPeers(), 21011)
	b := newTestPeer(t, server.URL, "peer-B", twoPeers(), 21011)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	a.start(ctx)
	b.start(ctx)
	defer a.stop()
	defer b.stop()
	sleepCtx(ctx, 2*signalRefresh)
	available.Store(true)
	if _, err := waitBothLinksUp(t, a, b, 10*time.Second); err != nil {
		t.Fatalf("%v\n%s", err, sink.String())
	}
}

func TestLeaderlessBrokerLossAndPeerRestart(t *testing.T) {
	for index, victimID := range []string{"peer-A", "peer-B"} {
		t.Run(victimID, func(t *testing.T) {
			sink := captureLogs(t)
			first, second := newTestBroker(), newTestBroker()
			defer first.Close()
			defer second.Close()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			port := 21012 + index
			a := newTestPeer(t, first.URL(), "peer-A", twoPeers(), port)
			b := newTestPeer(t, first.URL(), "peer-B", twoPeers(), port)
			for _, p := range []*testPeer{a, b} {
				p.mesh.cfg.SignalingURLs = []string{first.URL(), second.URL()}
			}
			a.start(ctx)
			b.start(ctx)
			defer a.stop()
			defer b.stop()
			if _, err := waitBothLinksUp(t, a, b, 10*time.Second); err != nil {
				t.Fatalf("%v\n%s", err, sink.String())
			}
			first.Close()
			victim := a
			if victimID == "peer-B" {
				victim = b
			}
			victim.stop()
			replacement := newTestPeer(t, second.URL(), victimID, twoPeers(), port)
			replacement.mesh.cfg.SignalingURLs = []string{first.URL(), second.URL()}
			replacement.start(ctx)
			defer replacement.stop()
			if victimID == "peer-A" {
				a = replacement
			} else {
				b = replacement
			}
			if _, err := waitBothLinksUp(t, a, b, 15*time.Second); err != nil {
				t.Fatalf("restart after broker loss: %v\n%s", err, sink.String())
			}
		})
	}
}

func TestSignalingConfigRejectsRelayAndInsecureOrigins(t *testing.T) {
	for _, endpoint := range []string{"http://public.example", "https://user:password@example.com", "https://example.com/path", "https://example.com/?token=secret"} {
		cfg := okConfig()
		cfg.SignalingURLs = []string{endpoint}
		if validateConfig(cfg) == nil {
			t.Fatalf("accepted %q", endpoint)
		}
	}
	for _, endpoint := range []string{"turn:example.com:3478", "turns:example.com:5349", "not a URL"} {
		cfg := okConfig()
		cfg.STUNURLs = []string{endpoint}
		if validateConfig(cfg) == nil {
			t.Fatalf("accepted %q", endpoint)
		}
	}
	cfg := okConfig()
	cfg.STUNURLs = []string{"stun:stun.cloudflare.com:3478", "stun:example.com:1234"}
	if err := validateConfig(cfg); err != nil {
		t.Fatal(err)
	}
	if signalToken(testSignalKey, "one", "peer") == signalToken(testSignalKey, "two", "peer") {
		t.Fatal("cluster namespaces collide")
	}
	if _, err := parseSignalingKey(strings.Repeat("x", 32)); err == nil {
		t.Fatal("invalid bootstrap key accepted")
	}
}

func TestBrokerStartupFailureIsFatal(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	cfg := signalTestConfig("peer-A")
	cfg.SignalingListen = listener.Addr().String()
	cfg.Allowlist = defaultAllowlist()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := newMesh(cfg).Run(ctx); err == nil {
		t.Fatal("broker bind failure must exit nonzero, not leave a nonfunctional mesh")
	}
}

func TestRetiredAgentCallbacksCannotCancelReplacement(t *testing.T) {
	oldAgent, newAgent := &ice.Agent{}, &ice.Agent{}
	oldCtx, oldCancel := context.WithCancel(context.Background())
	defer oldCancel()
	newCtx, newCancel := context.WithCancel(context.Background())
	defer newCancel()
	sess := &peerSession{agent: oldAgent, abortAttempt: oldCancel}

	// Reproduce the model's interleaving without sleeps: a callback has
	// started but cannot acquire the lock until the next attempt is installed.
	sess.mu.Lock()
	started, finished := make(chan struct{}), make(chan struct{})
	go func() {
		close(started)
		sess.abortAgent(oldAgent)
		close(finished)
	}()
	<-started
	oldCancel()
	sess.agent, sess.abortAttempt = newAgent, newCancel
	sess.mu.Unlock()
	select {
	case <-finished:
	case <-time.After(2 * time.Second):
		t.Fatal("retired callback did not finish")
	}
	if oldCtx.Err() == nil || newCtx.Err() != nil {
		t.Fatal("retired callback affected the replacement attempt")
	}
	// Positive control: the same callback path must cancel its own attempt.
	sess.abortAgent(newAgent)
	if newCtx.Err() == nil {
		t.Fatal("current-agent callback failed to cancel its own attempt")
	}
}
