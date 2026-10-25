package main

import (
	"context"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"
)

// TestSingleHandshake is the sanity test: bring up two peers with no
// race conditions and assert the link comes up. If this is flaky, the
// rest of the harness is unsound.
func TestSingleHandshake(t *testing.T) {
	sink := captureLogs(t)
	broker := newTestBroker()
	t.Cleanup(broker.Close)

	peers := twoPeers()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)

	a := newTestPeer(t, broker.URL(), "peer-A", peers, 21000)
	b := newTestPeer(t, broker.URL(), "peer-B", peers, 21000)
	t.Cleanup(a.stop)
	t.Cleanup(b.stop)
	a.start(ctx)
	b.start(ctx)

	elapsed, err := waitBothLinksUp(t, a, b, 30*time.Second)
	if err != nil {
		t.Fatalf("%v\n\nlogs:\n%s", err, sink.String())
	}
	t.Logf("single-handshake convergence: %s", elapsed)
}

// Inject an authenticated but stale answer, as if a lagging broker delivered
// a retired responder session. Its offer ID must prevent any renegotiation.
func (b *testBroker) publishAuth(from, to, ufrag, pwd string) {
	b.broker.mu.Lock()
	defer b.broker.mu.Unlock()
	key := [2]string{from, to}
	old := b.broker.records[key]
	r := signalRecord{From: from, To: to, Boot: strings.Repeat("f", 32), Clock: old.record.Clock + 1,
		Auth: [2]string{ufrag, pwd}, Offer: "retired-offer", Candidates: []string{}}
	r.MAC = r.signature(signalSigningKey(testSignalKey, "test", from))
	b.broker.records[key] = leasedRecord{r, time.Now().Add(signalLease)}
}

func TestStaleAnswerCannotRestartHealthyLink(t *testing.T) {
	sink := captureLogs(t)
	broker := newTestBroker()
	defer broker.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	a := newTestPeer(t, broker.URL(), "peer-A", twoPeers(), 21001)
	b := newTestPeer(t, broker.URL(), "peer-B", twoPeers(), 21001)
	a.start(ctx)
	b.start(ctx)
	defer a.stop()
	defer b.stop()
	if _, err := waitBothLinksUp(t, a, b, 10*time.Second); err != nil {
		t.Fatalf("%v\n%s", err, sink.String())
	}
	session := a.mesh.currentSession("peer-B")
	session.mu.Lock()
	originalAgent := session.agent
	session.mu.Unlock()
	broker.publishAuth("peer-B", "peer-A", "stale-ufrag", "stale-password-01234567890123456789")
	sleepCtx(ctx, 2*signalRefresh)
	session.mu.Lock()
	same := session.agent == originalAgent && session.linkUp
	session.mu.Unlock()
	if !same || len(a.linkUp) != 0 {
		t.Fatalf("stale answer restarted a healthy link\n%s", sink.String())
	}
}

// TestRestartConvergence simulates a real peer restart mid-link: kill
// peer-A's Mesh, build a fresh one with the same identity, and assert
// the new peer-A and the still-running peer-B converge to link-up.
//
// This is the second deterministic regression path: even on a clean
// (no forged auth) restart, the symmetry of "both sides see fresh
// auth from each other in close succession" is what triggers the
// flap when the fix isn't in place.
func TestRestartConvergence(t *testing.T) {
	sink := captureLogs(t)
	broker := newTestBroker()
	t.Cleanup(broker.Close)

	peers := twoPeers()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)

	a := newTestPeer(t, broker.URL(), "peer-A", peers, 21002)
	b := newTestPeer(t, broker.URL(), "peer-B", peers, 21002)
	t.Cleanup(b.stop)
	a.start(ctx)
	b.start(ctx)

	// First handshake — should always succeed.
	if _, err := waitBothLinksUp(t, a, b, 30*time.Second); err != nil {
		a.stop()
		t.Fatalf("initial link-up failed: %v\n\nlogs:\n%s", err, sink.String())
	}

	// Restart peer-A. Peer-B keeps running. Its consumedAuth is set
	// against peer-A's old auth — when the new peer-A publishes fresh
	// auth, peer-B will supersede its attempt and retry. This is the
	// asymmetric-restart pattern that triggered the live-cluster bug.
	a.stop()
	a2 := newTestPeer(t, broker.URL(), "peer-A", peers, 21002)
	t.Cleanup(a2.stop)
	a2.start(ctx)

	elapsed, err := waitBothLinksUp(t, a2, b, 30*time.Second)
	if err != nil {
		supersedes := sink.countLines("supersedes consumed")
		t.Fatalf("post-restart convergence failed: %v after %s\n  supersession count: %d\n\nlogs:\n%s",
			err, elapsed, supersedes, sink.String())
	}
	t.Logf("restart convergence: %s", elapsed)
}

// TestSteadyStateNoFlap brings two peers up on host loopback and then
// keeps them up for an extended observation window, asserting the ICE
// state never leaves Connected. The observation window is by default
// 5 minutes but can be shortened via STEADY_STATE_OBSERVE_SECONDS for
// the CI 50-trial regression sweep (e.g. 30 s).
//
// The point of the test is to disentangle two failure modes:
//
//   - "ICE state cycles even on host loopback (no NAT, no TURN, no
//     packet loss)" — implicates the mesh-conn outer state machine
//     (e.g. an abortAttempt path firing on a non-failure signal).
//
//   - "ICE state stays Connected on loopback" — exonerates the
//     mesh-conn outer code and points at the relay/TURN path.
//
// The signal we count is the number of ICE-state lines that AREN'T
// "Connected" emitted after the initial link-up (so the lines for
// the initial New → Checking → Connected handshake don't count). Any
// transition to Disconnected/Failed/Closed inside the observation
// window fails the test.
func TestSteadyStateNoFlap(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping steady-state observation in -short mode")
	}
	observe := 5 * time.Minute
	if v := os.Getenv("STEADY_STATE_OBSERVE_SECONDS"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 {
			t.Fatalf("STEADY_STATE_OBSERVE_SECONDS=%q invalid", v)
		}
		observe = time.Duration(n) * time.Second
	}

	sink := captureLogs(t)
	broker := newTestBroker()
	t.Cleanup(broker.Close)

	peers := twoPeers()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)

	a := newTestPeer(t, broker.URL(), "peer-A", peers, 21003)
	b := newTestPeer(t, broker.URL(), "peer-B", peers, 21003)
	t.Cleanup(a.stop)
	t.Cleanup(b.stop)
	a.start(ctx)
	b.start(ctx)

	if _, err := waitBothLinksUp(t, a, b, 30*time.Second); err != nil {
		t.Fatalf("initial link-up failed: %v\n\nlogs:\n%s", err, sink.String())
	}

	// snapshot the log so we can later count only post-link-up state
	// transitions. The initial handshake emits "ice state: Checking"
	// and "ice state: Connected" which we want to ignore.
	preObserve := sink.String()
	preFailed := strings.Count(preObserve, "ice state: Failed")
	preDisconnected := strings.Count(preObserve, "ice state: Disconnected")
	preClosed := strings.Count(preObserve, "ice state: Closed")
	preLinkClosed := strings.Count(preObserve, "link closed — reconnecting")
	preLinkFailed := strings.Count(preObserve, "link failed:")

	t.Logf("steady-state observation begins; window=%s", observe)
	time.Sleep(observe)

	post := sink.String()
	failed := strings.Count(post, "ice state: Failed") - preFailed
	disconnected := strings.Count(post, "ice state: Disconnected") - preDisconnected
	closed := strings.Count(post, "ice state: Closed") - preClosed
	linkClosed := strings.Count(post, "link closed — reconnecting") - preLinkClosed
	linkFailed := strings.Count(post, "link failed:") - preLinkFailed

	if failed+disconnected+closed+linkClosed+linkFailed > 0 {
		t.Fatalf("link flapped in steady state over %s: failed=%d disconnected=%d closed=%d linkClosed=%d linkFailed=%d\n\nlogs (post link-up):\n%s",
			observe, failed, disconnected, closed, linkClosed, linkFailed,
			strings.TrimPrefix(post, preObserve))
	}
	t.Logf("steady-state OK: no ice-state regressions over %s", observe)
}
