// mesh-conn — userspace port-forwarding agent over pion/ice + QUIC.
//
// Addressing model: peer VIPs + platform-supplied port allowlist.
//
//   Every peer is identified by a /8 loopback IP `127.50.0.<vip>`. The
//   `vip` is a small integer (typically the peer's ordinal in the
//   cluster) declared in PEERS_JSON, byte-identical across the cluster.
//
//   On every peer's host:
//   - the entrypoint provisions `127.50.0.<vip>/32 dev lo` for ALL
//     peers, including self — so dialing self's VIP loops back through
//     the kernel without crossing mesh-conn.
//   - mesh-conn binds the allowlist on every OTHER peer's VIP — and
//     forwards each accepted connection to the right remote peer over
//     QUIC.
//
// Allowlist source: MESH_CONN_ALLOWLIST env, JSON shape `[{port, udp}, …]`.
// Populated by the platform sidecar entrypoint at startup from
// MESH_ROUTES_JSON (producer Connect-sidecar ports) plus the static
// Consul-infra ports {8300, 8301}. The substance — which ports cross peer
// boundaries — is platform state declared one level up in `cluster.tf`'s
// `local.workload_groups`; mesh-conn just reads what the platform tells it.
//
// Today's defaults (3-service example: webdemo + postgres-master/-replica):
//
//   21000  Envoy Connect public mTLS — postgres sidecar        (TCP)
//   21001  Envoy Connect public mTLS — webdemo sidecar         (TCP)
//   8300   Consul server RPC                                   (TCP)
//   8301   Consul serf-LAN gossip                              (UDP + TCP)
//
// Sidecar ports come in one-per-backend because stock Consul Connect
// requires one sidecar Envoy process per Connect-mesh-accessible
// service. Services sharing a canonical port (postgres-master and
// postgres-replica both on :5432, same Patroni backend) collapse onto
// one sidecar; distinct canonical ports get distinct sidecars and
// distinct allowlist entries.
//
// The allowlist is intentionally minimal: only platform infrastructure
// that needs unmediated peer-to-peer reachability. App-level traffic
// (including Patroni's Postgres replication) goes through the Connect
// mesh — mesh-conn knows peers, never services.
//
// Wire format on each QUIC stream is unchanged from the old shape:
// the first 3 bytes are (tag, port-big-endian-uint16), where port is
// the receiver's local port to dial / write into. The receiver
// validates port against the allowlist and rejects anything else.
//
// Why QUIC and not yamux: yamux assumes a reliable byte-stream underlay,
// but pion/ice.Conn is UDP — and the UDP path between dstack worker
// CVMs is extremely lossy under sustained load (hairpinning the same
// public IP loses ~99% of bulk packets, coturn-relay loses ~78%).
// yamux's keepalive/recv-window invariants then trip and the user-
// visible error is "keepalive timeout" or "recv window exceeded", but
// the root cause is dropped packets. QUIC has built-in loss recovery,
// congestion control, and stream-multiplexing — it's exactly what a
// lossy UDP underlay needs. The previous yamux build died at 3KB-260KB
// depending on path; current service-mesh bandwidth is documented in
// docs/architecture.md from real-env benchmarks.

package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha1"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/ice/v2"
	"github.com/pion/logging"
	"github.com/pion/stun"
	"github.com/quic-go/quic-go"
)

// =============================================================================
// config
// =============================================================================

type Peer struct {
	ID  string `json:"id"`
	Vip int    `json:"vip"` // last octet in 127.50.0.0/24 — identifies this peer cluster-wide
}

// vipAddr returns 127.50.0.<vip> as a net.IP for binding listeners.
func (p *Peer) vipAddr() net.IP {
	return net.IPv4(127, 50, 0, byte(p.Vip))
}

// InfraPort is one entry in the peer-VIP port allowlist. mesh-conn
// binds (peer.vipAddr(), Port) on every OTHER peer for each entry.
// JSON-tagged because the value comes in over MESH_CONN_ALLOWLIST env.
type InfraPort struct {
	Port int  `json:"port"`
	UDP  bool `json:"udp"` // some ports carry UDP (e.g. serf gossip); most are TCP-only
}

type Config struct {
	SelfID          string
	ClusterName     string
	Peers           []Peer
	Allowlist       []InfraPort
	SignalingURLs   []string
	SignalingKey    []byte
	SignalingListen string
	STUNURLs        []string
}

// allowedPort reports whether the given port is in the allowlist.
// Used by the receiver to reject streams targeting unknown ports.
func (c *Config) allowedPort(port int) bool {
	for _, ip := range c.Allowlist {
		if ip.Port == port {
			return true
		}
	}
	return false
}

func loadConfig() *Config {
	// Primary sources of truth (with env fallback so this binary
	// stays runnable in a bare-metal smoke test outside the dstack
	// runtime):
	//
	//   - SELF identity comes from /run/instance/info.json written by
	//     the bootstrap-secrets init container (which read it from the
	//     dstack SDK's Info() call). Falls back to PEER_ID env.
	//   - STUN_URLS_JSON contains STUN endpoints only; relays are unsupported.
	//   - SIGNALING_URLS_JSON contains every independently reachable broker.
	//   - PEERS_JSON still comes via env — cluster.tf computes it from
	//     the `replicas` count and re-applies on topology change,
	//     which propagates to every CVM via Phala's in-place compose
	//     update path.

	cfg := &Config{
		SelfID:          readSelfID(),
		ClusterName:     mustEnv("CLUSTER_NAME"),
		SignalingListen: os.Getenv("SIGNALING_LISTEN"),
	}
	if err := json.Unmarshal([]byte(mustEnv("SIGNALING_URLS_JSON")), &cfg.SignalingURLs); err != nil {
		log.Fatalf("SIGNALING_URLS_JSON: %v", err)
	}
	if err := json.Unmarshal([]byte(mustEnv("STUN_URLS_JSON")), &cfg.STUNURLs); err != nil {
		log.Fatalf("STUN_URLS_JSON: %v", err)
	}
	var keyErr error
	cfg.SignalingKey, keyErr = parseSignalingKey(mustEnv("GOSSIP_KEY"))
	if keyErr != nil {
		log.Fatal(keyErr)
	}
	if err := json.Unmarshal([]byte(mustEnv("PEERS_JSON")), &cfg.Peers); err != nil {
		log.Fatalf("PEERS_JSON: %v", err)
	}
	// MESH_CONN_ALLOWLIST: JSON list `[{port, udp}, …]` generated by
	// the platform sidecar entrypoint from MESH_ROUTES_JSON (producer
	// Connect-sidecar ports) plus the static Consul-infra ports
	// (8300 RPC + 8301 gossip). This is platform plumbing; developers
	// edit `local.workload_groups` in cluster.tf, not this env.
	if err := json.Unmarshal([]byte(mustEnv("MESH_CONN_ALLOWLIST")), &cfg.Allowlist); err != nil {
		log.Fatalf("MESH_CONN_ALLOWLIST: %v", err)
	}
	if err := validateConfig(cfg); err != nil {
		log.Fatalf("config: %v", err)
	}
	return cfg
}

// readSelfID prefers /run/instance/info.json over PEER_ID env (the
// env path is kept so this binary stays runnable in a bare-metal
// smoke test). The JSON is written by bootstrap-secrets and gives
// us a per-CVM identifier rooted in the platform.
func readSelfID() string {
	if b, err := os.ReadFile("/run/instance/info.json"); err == nil {
		var info struct {
			Role    string `json:"role"`
			Ordinal int    `json:"ordinal"`
		}
		if jerr := json.Unmarshal(b, &info); jerr == nil && info.Role != "" {
			id := fmt.Sprintf("%s-%d", info.Role, info.Ordinal)
			log.Printf("self identity from /run/instance/info.json: %s", id)
			return id
		}
		log.Printf("WARN /run/instance/info.json present but unparseable; falling back to PEER_ID env: %v", err)
	}
	return mustEnv("PEER_ID")
}

// validateConfig fails fast on any silent mis-configuration that
// would otherwise manifest as confusing runtime failures: collided
// peer VIPs, missing self, malformed allowlist, etc. Bound at startup
// because PEERS_JSON and MESH_CONN_ALLOWLIST are shared cluster-wide
// state and must round-trip identically across peers.
func validateConfig(cfg *Config) error {
	if err := validatePeers(cfg); err != nil {
		return err
	}
	if err := validateAllowlist(cfg); err != nil {
		return err
	}
	if len(cfg.SignalingKey) != 32 {
		return fmt.Errorf("signaling requires a 32-byte key")
	}
	if len(cfg.SignalingURLs) == 0 && cfg.SignalingListen == "" {
		return fmt.Errorf("signaling URLs are required for workload peers")
	}
	seenURLs := map[string]bool{}
	for _, raw := range cfg.SignalingURLs {
		u, err := url.Parse(raw)
		if err != nil || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") || (u.Scheme != "https" && !(u.Scheme == "http" && net.ParseIP(u.Hostname()).IsLoopback())) {
			return fmt.Errorf("signaling URL must be HTTPS (HTTP is allowed only on loopback): %q", raw)
		}
		if seenURLs[raw] {
			return fmt.Errorf("duplicate signaling URL %q", raw)
		}
		seenURLs[raw] = true
	}
	for _, raw := range cfg.STUNURLs {
		u, err := stun.ParseURI(raw)
		if err != nil || u.Scheme != stun.SchemeTypeSTUN {
			return fmt.Errorf("only STUN URLs are supported, got %q", raw)
		}
	}
	// Log a digest of the validated config so operators can check that
	// every peer in the cluster sees the same PEERS_JSON. Differences
	// across peers would indicate a deploy-script discrepancy.
	digest := peersDigest(cfg.Peers)
	log.Printf("config validated: %d peers, allowlist=%d ports/peer (%v), digest=%s",
		len(cfg.Peers), len(cfg.Allowlist), allowlistPorts(cfg.Allowlist), digest)
	return nil
}

func validatePeers(cfg *Config) error {
	if len(cfg.Peers) < 2 {
		return fmt.Errorf("need at least 2 peers in PEERS_JSON, got %d", len(cfg.Peers))
	}

	seenIDs := map[string]bool{}
	allVips := map[int]string{} // vip -> peer.ID owning it (for collision detection)
	selfFound := false

	for i, p := range cfg.Peers {
		if p.ID == "" {
			return fmt.Errorf("peer[%d] has empty id", i)
		}
		if seenIDs[p.ID] {
			return fmt.Errorf("peer id %q appears twice in PEERS_JSON", p.ID)
		}
		seenIDs[p.ID] = true
		if p.ID == cfg.SelfID {
			selfFound = true
		}

		// VIP is the last octet of 127.50.0.0/24; must be 1..254
		// (avoid network 0 and broadcast 255 by convention) and unique
		// cluster-wide.
		if p.Vip < 1 || p.Vip > 254 {
			return fmt.Errorf("peer %q vip=%d out of range (1..254)", p.ID, p.Vip)
		}
		if owner, ok := allVips[p.Vip]; ok {
			return fmt.Errorf("vip %d is claimed by both peer %q and peer %q — every peer VIP must be globally unique",
				p.Vip, owner, p.ID)
		}
		allVips[p.Vip] = p.ID
	}

	if !selfFound {
		return fmt.Errorf("PEER_ID %q not in PEERS_JSON (peers: %v)", cfg.SelfID, knownIDs(cfg.Peers))
	}
	return nil
}

// validateAllowlist fails fast on MESH_CONN_ALLOWLIST malformations:
// empty list (mesh-conn with nothing to forward is always a config
// bug), out-of-range ports, or duplicate port entries (would race for
// the same listener bind at runtime).
func validateAllowlist(cfg *Config) error {
	if len(cfg.Allowlist) == 0 {
		return fmt.Errorf("MESH_CONN_ALLOWLIST is empty — platform sidecar should always emit at least the Consul-infra ports")
	}
	seen := map[int]bool{}
	for i, ip := range cfg.Allowlist {
		if ip.Port < 1 || ip.Port > 65535 {
			return fmt.Errorf("allowlist[%d] port=%d out of range (1..65535)", i, ip.Port)
		}
		if seen[ip.Port] {
			return fmt.Errorf("allowlist port %d appears twice — each port may only be entered once", ip.Port)
		}
		seen[ip.Port] = true
	}
	return nil
}

func knownIDs(peers []Peer) []string {
	ids := make([]string, 0, len(peers))
	for _, p := range peers {
		ids = append(ids, p.ID)
	}
	return ids
}

// allowlistPorts returns the bare port numbers for log output.
func allowlistPorts(allowlist []InfraPort) []int {
	out := make([]int, len(allowlist))
	for i, ip := range allowlist {
		out[i] = ip.Port
	}
	return out
}

// peersDigest is a short stable hash of the canonical PEERS_JSON used
// only to make config-drift diagnosable across peers' logs.
func peersDigest(peers []Peer) string {
	keys := make([]string, len(peers))
	for i, p := range peers {
		keys[i] = p.ID
	}
	// Stable sort by ID so a re-ordered PEERS_JSON gives the same digest.
	// Then encode as a deterministic string.
	for i := 1; i < len(keys); i++ {
		for j := i; j > 0 && keys[j] < keys[j-1]; j-- {
			keys[j], keys[j-1] = keys[j-1], keys[j]
		}
	}
	var buf strings.Builder
	for _, id := range keys {
		buf.WriteString(id)
		buf.WriteByte(':')
		// find peer
		for _, p := range peers {
			if p.ID == id {
				fmt.Fprintf(&buf, "vip=%d", p.Vip)
				break
			}
		}
		buf.WriteByte('|')
	}
	h := sha1.Sum([]byte(buf.String()))
	return base64.RawStdEncoding.EncodeToString(h[:])[:12]
}

func (c *Config) peerByID(id string) *Peer {
	for i := range c.Peers {
		if c.Peers[i].ID == id {
			return &c.Peers[i]
		}
	}
	return nil
}

func mustEnv(k string) string {
	v := os.Getenv(k)
	if v == "" {
		log.Fatalf("missing env %s", k)
	}
	return v
}

// =============================================================================
// main
// =============================================================================

func main() {
	flag.Parse()
	cfg := loadConfig()
	m := newMesh(cfg)
	if err := m.Run(context.Background()); err != nil {
		log.Fatal(err)
	}
}

// Mesh is one runtime instance — one mesh-conn process. Owns the
// per-peer session registry, signalling URL, and shutdown plumbing.
// Methods that previously closed over the package-level `sessions`
// map now receive *Mesh; main() builds one and calls Run().
//
// Reason for instance-scoping: the in-process loopback test boots two
// Mesh values side by side; a package-global session map collides
// across instances.
type Mesh struct {
	cfg       *Config
	self      *Peer
	signaling *signalClient
	// Agent construction is injected by virtual-NAT integration tests.
	// Production always uses ice.NewAgent.
	newAgent func(*ice.AgentConfig) (*ice.Agent, error)

	sessionsMu sync.Mutex
	sessions   map[string]*peerSession

	// onLinkUp is an optional test hook fired right after each
	// per-peer "link up" log line. nil in production.
	onLinkUp func(peerID string)

	// onAttemptStarted is an optional test hook fired when a per-peer
	// dialICE attempt has consumed the remote auth and is about to
	// call agent.Dial/Accept. Used by the auth-race test to
	// synchronise the race-trigger injection with the precise moment
	// the bug requires (consumedAuth set, dial in flight). nil in
	// production.
	onAttemptStarted func(peerID string)
}

func newMesh(cfg *Config) *Mesh {
	return &Mesh{
		cfg:       cfg,
		self:      cfg.peerByID(cfg.SelfID),
		signaling: newSignalClient(cfg),
		newAgent:  ice.NewAgent,
		sessions:  map[string]*peerSession{},
	}
}

func (m *Mesh) Run(ctx context.Context) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	serverErrors := make(chan error, 1)
	if m.cfg.SignalingListen != "" {
		server := &http.Server{Addr: m.cfg.SignalingListen, Handler: newSignalBroker(m.cfg),
			ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second,
			IdleTimeout: 30 * time.Second, MaxHeaderBytes: 8192}
		go func() {
			if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
				log.Printf("signaling listener: %v", err)
				serverErrors <- err
				cancel()
			}
		}()
		defer server.Close()
	}
	others := make([]Peer, 0, len(m.cfg.Peers)-1)
	for _, p := range m.cfg.Peers {
		if p.ID != m.cfg.SelfID {
			others = append(others, p)
		}
	}
	log.Printf("mesh-conn: self=%s vip=%d allowlist=%v other=%d",
		m.cfg.SelfID, m.self.Vip, allowlistPorts(m.cfg.Allowlist), len(others))

	// Install all sessions before reading snapshots; delivery must not depend
	// on which per-link goroutine happens to start first.
	for _, p := range others {
		m.setupPeerSession(p.ID)
	}
	var signalingWG sync.WaitGroup
	signalingWG.Add(1)
	go func() { defer signalingWG.Done(); m.signaling.run(ctx, m.applySignalRecord) }()

	var wg sync.WaitGroup
	for _, p := range others {
		wg.Add(1)
		go func(p Peer) {
			defer wg.Done()
			m.runPeerLink(ctx, p)
		}(p)
	}
	wg.Wait()
	cancel()
	signalingWG.Wait()
	log.Printf("all peer links exited")
	select {
	case err := <-serverErrors:
		return err
	default:
		return nil
	}
}

// =============================================================================
// per-peer link: ICE conn + bound UDP socket on peer's identity port
// =============================================================================

func (m *Mesh) runPeerLink(ctx context.Context, peer Peer) {
	// One peerSession per peer for the lifetime of mesh-conn. The
	// session holds authCh + candidateBuffer + abortAttempt — the
	// stable wiring snapshot delivery dispatches through. The ICE agent itself
	// is rebuilt per attempt inside dialICE (pion's Restart() doesn't
	// support re-Dial; see peerSession docstring).
	sess := m.currentSession(peer.ID)
	for {
		if ctx.Err() != nil {
			return
		}
		backoff := retryBackoff(m.cfg.SelfID, peer.ID)
		if err := m.dialAndPump(ctx, peer, sess); err != nil {
			log.Printf("[%s] link failed: %v — retrying in %s", peer.ID, err, backoff)
			if !sleepCtx(ctx, backoff) {
				return
			}
			continue
		}
		// dialAndPump returns nil only when the conn closed cleanly.
		log.Printf("[%s] link closed — reconnecting", peer.ID)
	}
}

// Retries are rate-limited, not used to elect a handshake initiator.
func retryBackoff(_, _ string) time.Duration { return 2 * time.Second }

// sleepCtx sleeps for d or until ctx is cancelled. Returns true if
// the full sleep completed (so the caller should continue), false if
// the caller should bail.
func sleepCtx(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return true
	case <-ctx.Done():
		return false
	}
}

// Stream header layout: 3 bytes per stream open.
//
//	byte 0 = tag (streamUDP or streamTCP)
//	bytes 1-2 = receiver-side port (big-endian uint16) — the port number
//	  the receiver itself binds locally; receiver looks it up in its own
//	  Ports list to find the index/protocol slot
const (
	streamUDP byte = 0x55 // long-lived per-port UDP datagram pipe
	streamTCP byte = 0x33 // per-conn TCP byte-stream forwarder
)

// quicConfig is shared by client and server. We give QUIC large windows
// so a pg_basebackup stream (sustained 100s of MB) doesn't stall on
// flow-control updates: a single InitialConnectionReceiveWindow of 8 MiB
// lets the sender push a chunk that big before needing an ACK from us.
// MaxIdleTimeout is what we use to detect a dead link — if no packet
// arrives in this long, the conn errors out.
func quicConfig() *quic.Config {
	return &quic.Config{
		KeepAlivePeriod:                10 * time.Second,
		MaxIdleTimeout:                 60 * time.Second,
		InitialStreamReceiveWindow:     4 << 20,
		MaxStreamReceiveWindow:         16 << 20,
		InitialConnectionReceiveWindow: 8 << 20,
		MaxConnectionReceiveWindow:     32 << 20,
	}
}

func (m *Mesh) dialAndPump(parentCtx context.Context, peer Peer, sess *peerSession) error {
	cfg := m.cfg
	self := *m.self
	// One attemptCtx for the entire attempt — covers dialICE, QUIC dial,
	// and the long-running pump goroutines. snapshot delivery and the ICE state
	// callback both wire abortAttempt to this ctx; cancelling it makes
	// the whole pile collapse so runPeerLink's retry can re-enter.
	// parentCtx (from Mesh.Run) is the outer shutdown signal; cancelling
	// it also collapses the attempt.
	attemptCtx, abort := context.WithCancel(parentCtx)
	sess.mu.Lock()
	sess.consumedAuth = [2]string{}
	sess.localOffer = ""
	sess.agent = nil
	if cfg.SelfID < peer.ID {
		// Answers/candidates to the previous offer cannot enter the next ICE
		// agent. Responders retain the current offer until they can answer it.
		sess.remoteAuth = [2]string{}
		sess.candidateBuffer = nil
		sess.candidateSet = map[string]bool{}
	}
	select {
	case <-sess.authCh:
	default:
	}
	sess.linkUp = false
	sess.abortAttempt = abort
	sess.mu.Unlock()
	defer func() {
		abort()
		sess.mu.Lock()
		// Only clear if it's still ours. runPeerLink's loop is serial
		// per peer so this is always the case, but defensive.
		if sess.abortAttempt != nil {
			sess.abortAttempt = nil
		}
		sess.linkUp = false
		sess.mu.Unlock()
	}()

	// 1. Establish ICE + wrap with a counting conn for byte-level telemetry.
	rawConn, err := m.dialICE(peer.ID, sess, attemptCtx)
	if err != nil {
		return fmt.Errorf("ice: %w", err)
	}
	// ice.Conn.Close() also closes the underlying agent (pion ties
	// their lifetimes — transport.go:112). That's exactly what we want
	// at end-of-attempt: this iteration's agent goes away, and the
	// next iteration installs a fresh one.
	defer rawConn.Close()
	counted := newCountingConn(rawConn, peer.ID)
	pkt := &iceConnPacketConn{conn: counted}

	// 2. Establish a QUIC connection on top of the ICE PacketConn.
	//    We replaced yamux here because pion/ice.Conn's UDP underlay drops
	//    packets under sustained load (NAT hairpinning loss between dstack
	//    workers is ~99%; even relay-via-coturn loses ~78%). yamux assumes
	//    a reliable byte-stream and dies as "keepalive timeout" or "recv
	//    window exceeded" — protocol violations triggered by lost packets.
	//    QUIC has built-in loss recovery + congestion control, so a lossy
	//    UDP underlay is exactly what it expects. Stream multiplex API is
	//    a near-drop-in for yamux: OpenStreamSync / AcceptStream.
	isClient := cfg.SelfID < peer.ID
	connCtx := attemptCtx
	dialCtx, dialCancel := context.WithTimeout(connCtx, 30*time.Second)
	defer dialCancel()

	var qconn *quic.Conn
	if isClient {
		// remote net.Addr is ignored by our PacketConn shim (it only
		// knows about the one ICE peer); we still pass something non-nil
		// because quic.Dial uses it for SNI fallback / connection ID.
		qconn, err = quic.Dial(dialCtx, pkt, counted.RemoteAddr(), clientTLS(), quicConfig())
		if err != nil {
			return fmt.Errorf("quic dial: %w", err)
		}
	} else {
		ln, lerr := quic.Listen(pkt, serverTLS(), quicConfig())
		if lerr != nil {
			return fmt.Errorf("quic listen: %w", lerr)
		}
		// Close the listener once we have our one accepted conn — we
		// only want a single QUIC connection per ICE pair.
		acceptCtx, acceptCancel := context.WithTimeout(connCtx, 30*time.Second)
		qconn, err = ln.Accept(acceptCtx)
		acceptCancel()
		ln.Close()
		if err != nil {
			return fmt.Errorf("quic accept: %w", err)
		}
	}
	defer qconn.CloseWithError(0, "")

	// Periodic per-link telemetry. The counting conn tracks bytes through
	// the underlying ice.Conn (i.e. wire bytes including QUIC overhead).
	// QUIC's StreamCount isn't directly exposed, so we report just bytes.
	stopStats := make(chan struct{})
	go reportLinkStats(peer.ID, counted, stopStats)
	defer close(stopStats)

	// 3. Bind allowlist listeners on the peer's VIP. UDP only for ports
	//    flagged UDP=true (currently only 8301); TCP for every entry.
	//    Aliases like 127.50.0.<peer.Vip>/32 are provisioned by
	//    components/mesh-sidecar/entrypoint.sh before mesh-conn starts; failing
	//    here means the alias didn't get set up.
	peerVip := peer.vipAddr()
	udpSocks := map[int]*net.UDPConn{} // port -> listener (only UDP-bearing ports)
	tcpListeners := make([]*net.TCPListener, 0, len(cfg.Allowlist))
	for _, ip := range cfg.Allowlist {
		tl, err := net.ListenTCP("tcp", &net.TCPAddr{IP: peerVip, Port: ip.Port})
		if err != nil {
			return fmt.Errorf("tcp listen %s:%d: %w", peerVip, ip.Port, err)
		}
		defer tl.Close()
		tcpListeners = append(tcpListeners, tl)
		if ip.UDP {
			us, err := net.ListenUDP("udp", &net.UDPAddr{IP: peerVip, Port: ip.Port})
			if err != nil {
				return fmt.Errorf("udp listen %s:%d: %w", peerVip, ip.Port, err)
			}
			defer us.Close()
			udpSocks[ip.Port] = us
		}
	}

	// 4. Establish the per-UDP-port long-lived streams. Client opens
	//    them eagerly tagged with the allowlist port; server's accept
	//    loop matches them by header. Both sides also run an accept
	//    loop to handle ad-hoc incoming TCP streams.
	udpStreams := map[int]*quic.Stream{}
	allUDPReady := make(chan struct{})
	errCh := make(chan error, 4*len(cfg.Allowlist))

	udpPortCount := len(udpSocks)
	go func() {
		errCh <- runAcceptLoop(connCtx, qconn, cfg, &self, udpStreams, udpPortCount, allUDPReady)
	}()

	if isClient {
		for _, ip := range cfg.Allowlist {
			if !ip.UDP {
				continue
			}
			s, err := qconn.OpenStreamSync(connCtx)
			if err != nil {
				return fmt.Errorf("quic OpenStreamSync: %w", err)
			}
			hdr := []byte{streamUDP, byte(ip.Port >> 8), byte(ip.Port & 0xff)}
			if _, err := s.Write(hdr); err != nil {
				return fmt.Errorf("quic write hdr: %w", err)
			}
			udpStreams[ip.Port] = s
		}
		close(allUDPReady)
	} else if udpPortCount > 0 {
		select {
		case <-allUDPReady:
		case <-time.After(60 * time.Second):
			return fmt.Errorf("timeout waiting for UDP streams")
		}
	} else {
		close(allUDPReady)
	}

	log.Printf("[%s] link up — peer vip=127.50.0.%d, allowlist=%v (udp=%d, tcp=%d)",
		peer.ID, peer.Vip, allowlistPorts(cfg.Allowlist), udpPortCount, len(tcpListeners))
	sess.mu.Lock()
	sess.linkUp = true
	sess.mu.Unlock()
	if m.onLinkUp != nil {
		m.onLinkUp(peer.ID)
	}

	// 5. Start pumps. UDP: one bidirectional pump pair per UDP port.
	//    TCP: one accept-loop per port (each accepted conn opens an
	//    ephemeral streamTCP).
	for _, ip := range cfg.Allowlist {
		port := ip.Port
		if ip.UDP {
			us := udpSocks[port]
			st := udpStreams[port]
			go func() { errCh <- pumpUDPSockToStream(us, st) }()
			go func() {
				// Dispatch to the SELF VIP, not 127.0.0.1, so the
				// inbound packet lands on whatever (Consul, Envoy, ...)
				// is listening on this peer's own loopback alias. This
				// also keeps the source-port-preservation invariant
				// intact: the local listener's bound addr is the
				// remote peer's VIP, so the receiving service sees
				// "from peer-N" as the source.
				udpDst := &net.UDPAddr{IP: self.vipAddr(), Port: port}
				errCh <- pumpUDPStreamToSock(st, us, udpDst)
			}()
		}
	}
	for i, ip := range cfg.Allowlist {
		tl := tcpListeners[i]
		port := ip.Port
		go func() { errCh <- acceptLocalTCP(connCtx, tl, qconn, port) }()
	}
	return <-errCh
}

// runAcceptLoop handles every incoming QUIC stream from the peer.
// streamUDP headers are matched into udpStreams keyed by port; streamTCP
// triggers a Dial to <self-vip>:<port> (so it lands on whatever the
// local Consul / Envoy bound on the peer's own loopback alias). The
// receiver validates port against the runtime allowlist from
// MESH_CONN_ALLOWLIST; anything else is rejected — that's the only
// port-knowledge the receiver needs.
func runAcceptLoop(ctx context.Context, qconn *quic.Conn, cfg *Config, self *Peer, udpStreams map[int]*quic.Stream, expectedUDP int, allUDPReady chan struct{}) error {
	udpRegistered := 0
	for {
		s, err := qconn.AcceptStream(ctx)
		if err != nil {
			return fmt.Errorf("quic accept: %w", err)
		}
		hdr := make([]byte, 3)
		if _, err := io.ReadFull(s, hdr); err != nil {
			s.CancelRead(0)
			s.Close()
			continue
		}
		tag := hdr[0]
		port := int(hdr[1])<<8 | int(hdr[2])
		if !cfg.allowedPort(port) {
			log.Printf("stream for non-allowlist port %d (tag=0x%x)", port, tag)
			s.CancelRead(0)
			s.Close()
			continue
		}
		switch tag {
		case streamUDP:
			if _, dup := udpStreams[port]; dup {
				log.Printf("duplicate streamUDP for port %d", port)
				s.CancelRead(0)
				s.Close()
				continue
			}
			udpStreams[port] = s
			udpRegistered++
			if udpRegistered == expectedUDP {
				close(allUDPReady)
			}
		case streamTCP:
			go handleIncomingTCP(s, &net.TCPAddr{IP: self.vipAddr(), Port: port})
		default:
			log.Printf("unknown stream tag 0x%x", tag)
			s.CancelRead(0)
			s.Close()
		}
	}
}

func handleIncomingTCP(s *quic.Stream, dst *net.TCPAddr) {
	defer s.Close()
	c, err := net.DialTCP("tcp", nil, dst)
	if err != nil {
		log.Printf("dial local %s: %v", dst, err)
		return
	}
	defer c.Close()
	spliceBoth(s, c)
}

func acceptLocalTCP(ctx context.Context, lis *net.TCPListener, qconn *quic.Conn, dstPeerPort int) error {
	for {
		c, err := lis.AcceptTCP()
		if err != nil {
			return fmt.Errorf("tcp accept: %w", err)
		}
		go func(c *net.TCPConn) {
			defer c.Close()
			s, err := qconn.OpenStreamSync(ctx)
			if err != nil {
				log.Printf("quic open: %v", err)
				return
			}
			defer s.Close()
			hdr := []byte{streamTCP, byte(dstPeerPort >> 8), byte(dstPeerPort & 0xff)}
			if _, err := s.Write(hdr); err != nil {
				return
			}
			spliceBoth(s, c)
		}(c)
	}
}

func spliceBoth(a, b io.ReadWriteCloser) {
	done := make(chan struct{}, 2)
	go func() { io.Copy(a, b); done <- struct{}{} }()
	go func() { io.Copy(b, a); done <- struct{}{} }()
	<-done
}

// =============================================================================
// UDP-over-yamux: length-prefixed datagrams on the dedicated stream.
// =============================================================================

func pumpUDPSockToStream(sock *net.UDPConn, s *quic.Stream) error {
	buf := make([]byte, 1500)
	frame := make([]byte, 2+1500)
	for {
		n, _, err := sock.ReadFromUDP(buf)
		if err != nil {
			return fmt.Errorf("udp sock read: %w", err)
		}
		if n > 65535 {
			continue
		}
		binary.BigEndian.PutUint16(frame[:2], uint16(n))
		copy(frame[2:], buf[:n])
		if _, err := s.Write(frame[:2+n]); err != nil {
			return fmt.Errorf("udp stream write: %w", err)
		}
	}
}

func pumpUDPStreamToSock(s *quic.Stream, sock *net.UDPConn, dst *net.UDPAddr) error {
	hdr := make([]byte, 2)
	buf := make([]byte, 65536)
	for {
		if _, err := io.ReadFull(s, hdr); err != nil {
			return fmt.Errorf("udp stream read header: %w", err)
		}
		n := int(binary.BigEndian.Uint16(hdr))
		if _, err := io.ReadFull(s, buf[:n]); err != nil {
			return fmt.Errorf("udp stream read body: %w", err)
		}
		if _, err := sock.WriteToUDP(buf[:n], dst); err != nil {
			return fmt.Errorf("udp sock write: %w", err)
		}
	}
}

// =============================================================================
// Per-link instrumentation: count bytes through the ICE conn (i.e. the
// raw wire bytes including QUIC framing/encryption overhead) and log
// a periodic summary. Useful for diagnosing whether a link drop happens
// after 0 bytes, 1KB, or 100MB.
// =============================================================================

type countingConn struct {
	net.Conn
	peerID   string
	bytesIn  atomic.Uint64
	bytesOut atomic.Uint64
	reads    atomic.Uint64
	writes   atomic.Uint64
}

func newCountingConn(c net.Conn, peerID string) *countingConn {
	return &countingConn{Conn: c, peerID: peerID}
}

func (c *countingConn) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	c.bytesIn.Add(uint64(n))
	c.reads.Add(1)
	if err != nil {
		log.Printf("[%s] conn.Read err after %d bytes total / %d reads: %v",
			c.peerID, c.bytesIn.Load(), c.reads.Load(), err)
	}
	return n, err
}

func (c *countingConn) Write(p []byte) (int, error) {
	n, err := c.Conn.Write(p)
	c.bytesOut.Add(uint64(n))
	c.writes.Add(1)
	if err != nil {
		log.Printf("[%s] conn.Write err after %d bytes total / %d writes: %v",
			c.peerID, c.bytesOut.Load(), c.writes.Load(), err)
	}
	return n, err
}

// iceConnPacketConn adapts a pion/ice.Conn (packet-oriented net.Conn) to
// a net.PacketConn so quic-go can run on it. Every Read on ice.Conn
// returns one datagram; every Write sends one. The single-peer case
// means we can ignore the addr arg from quic and unconditionally route
// to the ICE peer that's already locked in.
type iceConnPacketConn struct {
	conn *countingConn
}

func (p *iceConnPacketConn) ReadFrom(b []byte) (int, net.Addr, error) {
	n, err := p.conn.Read(b)
	return n, p.conn.RemoteAddr(), err
}

func (p *iceConnPacketConn) WriteTo(b []byte, _ net.Addr) (int, error) {
	return p.conn.Write(b)
}

func (p *iceConnPacketConn) Close() error        { return p.conn.Close() }
func (p *iceConnPacketConn) LocalAddr() net.Addr { return p.conn.LocalAddr() }

// Deadline methods delegate to ice.Conn (via the embedded net.Conn on
// countingConn) instead of being a no-op. quic-go relies on
// SetReadDeadline to interrupt a blocked ReadFrom when its context
// cancels — without this delegation, a quic.Dial whose context times
// out (e.g. because ICE went Failed mid-handshake) would hang forever
// in our shim, and the surrounding runPeerLink retry loop never gets
// to retry. Pion's ice.Conn implements the deadline methods, so this
// is the natural place to wire them through.
func (p *iceConnPacketConn) SetDeadline(t time.Time) error      { return p.conn.SetDeadline(t) }
func (p *iceConnPacketConn) SetReadDeadline(t time.Time) error  { return p.conn.SetReadDeadline(t) }
func (p *iceConnPacketConn) SetWriteDeadline(t time.Time) error { return p.conn.SetWriteDeadline(t) }

// reportLinkStats logs a periodic summary per peer link. Once a minute,
// and only when bytes actually moved since the last tick, so an idle
// mesh stays quiet. Always logs the final summary on stop, regardless
// of activity, since that's what postmortems read.
func reportLinkStats(peerID string, conn *countingConn, stop <-chan struct{}) {
	t := time.NewTicker(60 * time.Second)
	defer t.Stop()
	var lastIn, lastOut uint64
	for {
		select {
		case <-stop:
			log.Printf("[%s] final stats: in=%d out=%d reads=%d writes=%d",
				peerID, conn.bytesIn.Load(), conn.bytesOut.Load(),
				conn.reads.Load(), conn.writes.Load())
			return
		case <-t.C:
			in, out := conn.bytesIn.Load(), conn.bytesOut.Load()
			if in == lastIn && out == lastOut {
				continue
			}
			log.Printf("[%s] link: in=%d (+%d B/min) out=%d (+%d B/min) reads=%d writes=%d",
				peerID, in, in-lastIn, out, out-lastOut,
				conn.reads.Load(), conn.writes.Load())
			lastIn, lastOut = in, out
		}
	}
}

// =============================================================================
// TLS — QUIC encrypts the transport using a self-signed certificate.
// This does not establish workload identity. Shared-key signaling protects
// rendezvous; attestation admission and Connect mTLS protect application
// identities separately. Do not treat QUIC as an attestation check.
// =============================================================================

const quicALPN = "dstack-mesh-conn"

func clientTLS() *tls.Config {
	return &tls.Config{
		InsecureSkipVerify: true,
		NextProtos:         []string{quicALPN},
	}
}

func serverTLS() *tls.Config {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		log.Fatalf("ecdsa keygen: %v", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "mesh-conn"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(365 * 24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &priv.PublicKey, priv)
	if err != nil {
		log.Fatalf("self-signed cert: %v", err)
	}
	return &tls.Config{
		Certificates: []tls.Certificate{{
			Certificate: [][]byte{der},
			PrivateKey:  priv,
		}},
		NextProtos: []string{quicALPN},
	}
}

// =============================================================================
// ICE — long-lived per-peer session, agent rebuilt per attempt
// =============================================================================

// Each pair has one deterministic initiator (the lower peer ID).
// It publishes an offer; the responder echoes that offer ID in its answer.
// All brokers feed this same session and ICE agent. Only a new offer or
// changed answer to the current offer invalidates an active attempt.
type peerSession struct {
	authCh chan [2]string

	mu              sync.Mutex
	agent           *ice.Agent         // replaced on every dialICE attempt; guarded by mu
	consumedAuth    [2]string          // ufrag,pwd dialICE pulled off authCh; zero before
	linkUp          bool               // true after QUIC + forwarders are established
	abortAttempt    context.CancelFunc // non-nil for the duration of an attempt
	candidateBuffer []ice.Candidate    // remote candidates seen since last peer-auth; replayed into each new agent
	localOffer      string
	remoteAuth      [2]string
	candidateSet    map[string]bool
}

// Delayed callbacks belong to their originating agent, not to whichever
// attempt currently occupies the session. In particular, Timer.Stop does not
// wait for an already-started callback blocked on this mutex.
func (sess *peerSession) abortAgent(agent *ice.Agent) {
	sess.mu.Lock()
	defer sess.mu.Unlock()
	if sess.agent == agent && sess.abortAttempt != nil {
		sess.abortAttempt()
	}
}

const (
	// pion transitions Checking -> Disconnected after this period without
	// a viable selected pair. Disconnected is log-only for mesh-conn.
	iceDisconnectedTimeout = 30 * time.Second

	// pion transitions Disconnected -> Failed after this additional
	// period. The ICE state callback aborts the attempt on Failed.
	iceFailedTimeout = 60 * time.Second

	// dialAttemptTimeout is only a guardrail for a stuck pion call path:
	// it must be longer than pion's own failure budget so mesh-conn does
	// not cancel a legitimate slow ICE attempt before the ICE state
	// machine reaches Failed.
	dialAttemptTimeout = iceDisconnectedTimeout + iceFailedTimeout + 15*time.Second
)

// currentSession returns the persistent session for remoteID, or nil
// if setupPeerSession hasn't installed it yet. Used by snapshot delivery to
// dispatch incoming messages to the right agent.
func (m *Mesh) currentSession(remoteID string) *peerSession {
	m.sessionsMu.Lock()
	defer m.sessionsMu.Unlock()
	return m.sessions[remoteID]
}

// setupPeerSession allocates the long-lived session shell (authCh,
// candidateBuffer, mutex) for one peer. The ICE agent itself is built
// per-attempt inside dialICE — see the peerSession docstring for why
// per-attempt rather than persistent.
func (m *Mesh) setupPeerSession(remoteID string) *peerSession {
	sess := &peerSession{
		authCh: make(chan [2]string, 1),
	}
	m.sessionsMu.Lock()
	m.sessions[remoteID] = sess
	m.sessionsMu.Unlock()
	return sess
}

func (m *Mesh) dialICE(remoteID string, sess *peerSession, attemptCtx context.Context) (*ice.Conn, error) {
	cfg := m.cfg
	var remote [2]string
	if cfg.SelfID > remoteID {
		var waitErr error
		remote, waitErr = waitSignalAuth(attemptCtx, sess)
		if waitErr != nil {
			return nil, waitErr
		}
	}
	var urls []*stun.URI
	for _, raw := range cfg.STUNURLs {
		u, err := stun.ParseURI(raw)
		if err != nil || u.Scheme != stun.SchemeTypeSTUN {
			return nil, fmt.Errorf("invalid STUN URL %q", raw)
		}
		urls = append(urls, u)
	}

	candidateTypes := []ice.CandidateType{
		ice.CandidateTypeHost,
		ice.CandidateTypeServerReflexive,
		ice.CandidateTypePeerReflexive,
	}
	// Preserve the existing transport liveness budget. Signaling snapshots
	// never extend it or restart established links without a new peer session.
	disconnectedTimeout := iceDisconnectedTimeout
	failedTimeout := iceFailedTimeout
	agentCfg := &ice.AgentConfig{
		Urls:                urls,
		NetworkTypes:        []ice.NetworkType{ice.NetworkTypeUDP4, ice.NetworkTypeTCP4},
		CandidateTypes:      candidateTypes,
		DisconnectedTimeout: &disconnectedTimeout,
		FailedTimeout:       &failedTimeout,
	}
	if os.Getenv("MESH_CONN_DEBUG_ICE") == "1" {
		lf := logging.NewDefaultLoggerFactory()
		lf.DefaultLogLevel = logging.LogLevelTrace
		agentCfg.LoggerFactory = lf
	}
	agent, err := m.newAgent(agentCfg)
	if err != nil {
		return nil, fmt.Errorf("NewAgent: %w", err)
	}
	// Install the agent in the session BEFORE any signalling so
	// snapshot delivery dispatches AddRemoteCandidate to this attempt. Any
	// agent from a previous attempt is dropped (it's already failed
	// or closed by the caller) — snapshot delivery captures the new pointer
	// under mu and uses that.
	sess.mu.Lock()
	sess.agent = agent
	sess.mu.Unlock()

	// On failure, close the agent before returning so pion's goroutines
	// don't leak. Successful path returns the conn; runPeerLink's outer
	// loop is responsible for closing it at end-of-attempt.
	closed := false
	defer func() {
		if !closed && err != nil {
			_ = agent.Close()
		}
	}()

	localUfrag, localPwd, err := agent.GetLocalUserCredentials()
	if err != nil {
		return nil, err
	}
	localAuth := [2]string{localUfrag, localPwd}
	offer := localUfrag
	if cfg.SelfID > remoteID {
		offer = remote[0]
	}
	sess.mu.Lock()
	sess.localOffer = offer
	if cfg.SelfID > remoteID && sess.remoteAuth != remote {
		sess.mu.Unlock()
		err = fmt.Errorf("offer changed before answer")
		return nil, err
	}
	sess.mu.Unlock()
	m.signaling.setAuthForOffer(remoteID, localAuth, offer)
	if err = agent.OnCandidate(func(c ice.Candidate) {
		if c == nil {
			return
		}
		if err := m.signaling.addCandidate(remoteID, localAuth, c.Marshal()); err != nil {
			log.Print(err)
			sess.abortAgent(agent)
		}
	}); err != nil {
		return nil, err
	}
	if err = agent.OnConnectionStateChange(func(s ice.ConnectionState) {
		log.Printf("[%s] ice state: %s", remoteID, s)
		if s == ice.ConnectionStateFailed || s == ice.ConnectionStateClosed {
			sess.abortAgent(agent)
		}
	}); err != nil {
		return nil, err
	}

	// Replay any remote candidates already buffered by snapshot delivery (sent
	// by peer before this iteration's agent was even constructed).
	// snapshot delivery also dispatches AddRemoteCandidate to the live agent for
	// every NEW candidate; this catch-up only matters for candidates
	// from peer's last gather that arrived during our retry window.
	sess.mu.Lock()
	buffered := append([]ice.Candidate(nil), sess.candidateBuffer...)
	sess.mu.Unlock()
	for _, c := range buffered {
		if err2 := agent.AddRemoteCandidate(c); err2 != nil {
			log.Printf("[%s] replay AddRemoteCandidate: %v", remoteID, err2)
		}
	}

	// The initiator only accepts answers addressed to this exact offer.
	if cfg.SelfID < remoteID {
		remote, err = waitSignalAuth(attemptCtx, sess)
		if err != nil {
			return nil, err
		}
	}
	sess.mu.Lock()
	if sess.remoteAuth != remote {
		sess.mu.Unlock()
		err = fmt.Errorf("remote session changed before ICE")
		return nil, err
	}
	sess.consumedAuth = remote
	sess.mu.Unlock()
	// An offer may wait minutes for a peer to boot. Allocate reflexive NAT
	// mappings only after both sides' credentials exist, immediately before
	// connectivity checks, so that offline time cannot age our candidates.
	// Publishing credentials first also lets the responder answer without
	// depending on candidate gathering or direct connectivity.
	if err = agent.GatherCandidates(); err != nil {
		return nil, err
	}
	if m.onAttemptStarted != nil {
		m.onAttemptStarted(remoteID)
	}

	// Safety net for a wedged Dial/Accept call path. This intentionally
	// exceeds pion's Checking+Disconnected failure budget; ordinary
	// failure is handled by the ICE Failed state callback above.
	dialTimer := time.AfterFunc(dialAttemptTimeout, func() {
		sess.abortAgent(agent)
	})
	defer dialTimer.Stop()

	var conn *ice.Conn
	if cfg.SelfID < remoteID {
		conn, err = agent.Dial(attemptCtx, remote[0], remote[1])
	} else {
		conn, err = agent.Accept(attemptCtx, remote[0], remote[1])
	}
	if err != nil {
		return nil, err
	}
	closed = true // success — let runPeerLink own the conn (and thus the agent)

	if pair, perr := agent.GetSelectedCandidatePair(); perr == nil && pair != nil {
		// Log full addresses + types so we can correlate stuck links against
		// direct NAT mappings.
		log.Printf("[%s] selected pair: %s %s:%d <-> %s %s:%d (proto=%s)",
			remoteID,
			pair.Local.Type(), pair.Local.Address(), pair.Local.Port(),
			pair.Remote.Type(), pair.Remote.Address(), pair.Remote.Port(),
			pair.Local.NetworkType().NetworkShort())
	}
	return conn, nil
}

// applySignalRecord receives an atomic full snapshot for one ICE attempt.
// The caller serializes broker deliveries; the session lock serializes agent
// replacement. Duplicated auth never resets candidate state or healthy links.
func (m *Mesh) applySignalRecord(r signalRecord) {
	sess := m.currentSession(r.From)
	if sess == nil {
		return
	}
	sess.mu.Lock()
	if m.cfg.SelfID < r.From {
		if r.Offer != sess.localOffer || sess.localOffer == "" {
			sess.mu.Unlock()
			return
		}
	} else if r.Offer != r.Auth[0] {
		sess.mu.Unlock()
		return
	}
	if sess.remoteAuth != r.Auth {
		sess.remoteAuth = r.Auth
		sess.candidateBuffer = nil
		sess.candidateSet = map[string]bool{}
		// A changed peer session is a protocol event, not a timing heuristic.
		// A responder follows new offers even before it consumes the auth.
		if sess.abortAttempt != nil && (sess.consumedAuth != [2]string{} ||
			(m.cfg.SelfID > r.From && sess.localOffer != "" && sess.localOffer != r.Offer)) {
			sess.abortAttempt()
		}
	}
	select {
	case <-sess.authCh:
	default:
	}
	sess.authCh <- r.Auth
	var newCandidates []ice.Candidate
	for _, raw := range r.Candidates {
		if sess.candidateSet[raw] {
			continue
		}
		c, err := ice.UnmarshalCandidate(raw)
		if err != nil || c.Type() == ice.CandidateTypeRelay {
			continue
		}
		sess.candidateSet[raw] = true
		sess.candidateBuffer = append(sess.candidateBuffer, c)
		newCandidates = append(newCandidates, c)
	}
	agent := sess.agent
	if sess.consumedAuth != [2]string{} && sess.consumedAuth != r.Auth {
		agent = nil
	}
	sess.mu.Unlock()
	// Never call pion while holding the session mutex: its state callbacks
	// acquire that mutex too. If the agent changes here, the replacement
	// replays candidateBuffer, so delivery to the old agent loses no state.
	if agent != nil {
		for _, c := range newCandidates {
			if err := agent.AddRemoteCandidate(c); err != nil {
				log.Printf("[%s] AddRemoteCandidate: %v", r.From, err)
			}
		}
	}
}

func waitSignalAuth(ctx context.Context, sess *peerSession) ([2]string, error) {
	select {
	case auth := <-sess.authCh:
		return auth, nil
	case <-ctx.Done():
		return [2]string{}, ctx.Err()
	}
}
