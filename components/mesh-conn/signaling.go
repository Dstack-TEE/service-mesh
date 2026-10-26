package main

// Leaderless rendezvous is a set of independent, bounded soft-state stores.
// Each peer repeatedly publishes complete signed per-pair snapshots to every
// store. A Lamport version orders snapshots; reading our previous incarnation's
// version advances our clock after a restart without requiring durable storage.
// Broker loss, lost responses and duplicate/reordered delivery need no queue
// transfer or consensus. Membership and the shared bootstrap key are provisioned
// independently of Consul and this transport does not grant mesh admission.

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/pion/ice/v2"
)

const (
	signalRefresh       = time.Second
	signalLease         = 2 * time.Minute
	signalTimeout       = 5 * time.Second
	signalMaxBody       = 1 << 20
	signalMaxCandidates = 64
)

type signalRecord struct {
	From       string    `json:"from"`
	To         string    `json:"to"`
	Boot       string    `json:"boot"`
	Clock      uint64    `json:"clock"`
	Auth       [2]string `json:"auth"`  // ufrag is also the ICE attempt identifier
	Offer      string    `json:"offer"` // initiator ufrag; answers echo the exact offer
	Candidates []string  `json:"candidates"`
	MAC        string    `json:"mac"`
}

func (a signalRecord) newer(b signalRecord) bool {
	return a.Clock > b.Clock || a.Clock == b.Clock && a.Boot > b.Boot
}

func signalToken(key []byte, cluster, peer string) string {
	return signalDerivedKey(key, cluster, peer, "access")
}

func signalSigningKey(key []byte, cluster, peer string) string {
	return signalDerivedKey(key, cluster, peer, "record")
}

func signalDerivedKey(key []byte, cluster, peer, purpose string) string {
	h := hmac.New(sha256.New, key)
	fmt.Fprintf(h, "dstack-mesh/signaling/v1\x00%s\x00%s\x00%s", purpose, cluster, peer)
	return hex.EncodeToString(h.Sum(nil))
}

func (r signalRecord) signature(token string) string {
	r.MAC = ""
	b, _ := json.Marshal(r)
	h := hmac.New(sha256.New, []byte(token))
	h.Write(b)
	return hex.EncodeToString(h.Sum(nil))
}

type signalExchange struct {
	Peer    string         `json:"peer"`
	Records []signalRecord `json:"records"`
}

type leasedRecord struct {
	record  signalRecord
	expires time.Time
}

type signalBroker struct {
	mu      sync.Mutex
	cluster string
	key     []byte
	peers   map[string]bool
	records map[[2]string]leasedRecord
	// Token buckets are bounded by provisioned membership, not caller input.
	limits map[string]*signalLimit
	now    func() time.Time
}

type signalLimit struct {
	tokens float64
	at     time.Time
}

func newSignalBroker(cfg *Config) *signalBroker {
	b := &signalBroker{cluster: cfg.ClusterName, key: cfg.SignalingKey,
		peers: map[string]bool{}, records: map[[2]string]leasedRecord{},
		limits: map[string]*signalLimit{}, now: time.Now}
	for _, p := range cfg.Peers {
		b.peers[p.ID] = true
	}
	return b
}

func (b *signalBroker) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	if req.URL.Path == "/healthz" && req.Method == http.MethodGet {
		_, _ = io.WriteString(w, "leaderless-signaling-v1\n")
		return
	}
	if req.URL.Path != "/v1/sync" || req.Method != http.MethodPost {
		http.Error(w, "POST /v1/sync required", http.StatusNotFound)
		return
	}
	peer := req.Header.Get("X-Mesh-Peer")
	token := signalToken(b.key, b.cluster, peer)
	if !b.peers[peer] || !hmac.Equal([]byte(req.Header.Get("Authorization")), []byte("Bearer "+token)) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	now := b.now()
	b.mu.Lock()
	limit := b.limits[peer]
	if limit == nil {
		limit = &signalLimit{tokens: 20, at: now}
		b.limits[peer] = limit
	}
	limit.tokens += now.Sub(limit.at).Seconds() * 10
	if limit.tokens > 20 {
		limit.tokens = 20
	}
	limit.at = now
	allowed := limit.tokens >= 1
	if allowed {
		limit.tokens--
	}
	b.mu.Unlock()
	if !allowed {
		http.Error(w, "rate limited", http.StatusTooManyRequests)
		return
	}
	req.Body = http.MaxBytesReader(w, req.Body, signalMaxBody)
	defer req.Body.Close()
	var exchange signalExchange
	decoder := json.NewDecoder(req.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&exchange); err != nil {
		http.Error(w, "invalid exchange", http.StatusBadRequest)
		return
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		http.Error(w, "trailing data", http.StatusBadRequest)
		return
	}
	if exchange.Peer != peer || len(exchange.Records) >= len(b.peers) {
		http.Error(w, "invalid membership", http.StatusBadRequest)
		return
	}
	seen := map[string]bool{}
	signingKey := signalSigningKey(b.key, b.cluster, peer)
	for _, r := range exchange.Records {
		if r.From != peer || r.To == peer || !b.peers[r.To] || seen[r.To] ||
			len(r.Boot) != 32 || r.Clock == 0 || r.Clock > 1<<63 ||
			len(r.Auth[0]) < 4 || len(r.Auth[0]) > 256 || len(r.Auth[1]) < 22 || len(r.Auth[1]) > 256 ||
			len(r.Offer) < 4 || len(r.Offer) > 256 || (r.From < r.To && r.Offer != r.Auth[0]) ||
			len(r.Candidates) > signalMaxCandidates || !hmac.Equal([]byte(r.MAC), []byte(r.signature(signingKey))) {
			http.Error(w, "invalid snapshot", http.StatusBadRequest)
			return
		}
		for _, c := range r.Candidates {
			if len(c) > 2048 {
				http.Error(w, "invalid candidate", http.StatusBadRequest)
				return
			}
			candidate, err := ice.UnmarshalCandidate(c)
			if err != nil || candidate.Type() == ice.CandidateTypeRelay {
				http.Error(w, "invalid or relayed candidate", http.StatusBadRequest)
				return
			}
		}
		seen[r.To] = true
	}
	b.mu.Lock()
	for k, v := range b.records {
		if !now.Before(v.expires) {
			delete(b.records, k)
		}
	}
	for _, r := range exchange.Records {
		k := [2]string{r.From, r.To}
		old, ok := b.records[k]
		if !ok || r.newer(old.record) {
			b.records[k] = leasedRecord{r, now.Add(signalLease)}
		}
	}
	// Return our own records too: they recover the Lamport clock on restart.
	result := signalExchange{Peer: peer, Records: []signalRecord{}}
	for _, v := range b.records {
		if v.record.To == peer || v.record.From == peer {
			result.Records = append(result.Records, v.record)
		}
	}
	b.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(result)
}

type signalClient struct {
	mu      sync.Mutex
	applyMu sync.Mutex // serializes deliveries from independent brokers
	cfg     *Config
	boot    string
	clock   uint64
	local   map[string]signalRecord
	remote  map[string]signalRecord
	wake    []chan struct{}
	client  *http.Client
}

func newSignalClient(cfg *Config) *signalClient {
	var boot [16]byte
	if _, err := rand.Read(boot[:]); err != nil {
		panic(err)
	}
	return &signalClient{cfg: cfg, boot: hex.EncodeToString(boot[:]),
		local: map[string]signalRecord{}, remote: map[string]signalRecord{},
		client: &http.Client{Timeout: signalTimeout, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
}

func (s *signalClient) setAuth(to string, auth [2]string) {
	s.setAuthForOffer(to, auth, auth[0])
}

func (s *signalClient) setAuthForOffer(to string, auth [2]string, offer string) {
	s.mu.Lock()
	s.local[to] = signalRecord{From: s.cfg.SelfID, To: to, Boot: s.boot, Auth: auth, Offer: offer, Candidates: []string{}}
	s.notifyLocked()
	s.mu.Unlock()
}

func (s *signalClient) addCandidate(to string, auth [2]string, candidate string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.local[to]
	if !ok || r.Auth != auth {
		return nil
	} // callback from a retired ICE agent
	for _, c := range r.Candidates {
		if c == candidate {
			return nil
		}
	}
	if len(r.Candidates) >= signalMaxCandidates {
		return fmt.Errorf("[%s] ICE candidate limit exceeded", to)
	}
	r.Candidates = append(r.Candidates, candidate)
	sort.Strings(r.Candidates)
	s.local[to] = r
	s.notifyLocked()
	return nil
}

func (s *signalClient) notifyLocked() {
	for _, wake := range s.wake {
		select {
		case wake <- struct{}{}:
		default:
		}
	}
}

func (s *signalClient) snapshot() signalExchange {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.clock++
	out := signalExchange{Peer: s.cfg.SelfID, Records: []signalRecord{}}
	token := signalSigningKey(s.cfg.SignalingKey, s.cfg.ClusterName, s.cfg.SelfID)
	for _, r := range s.local {
		r.Clock = s.clock
		r.Candidates = append([]string{}, r.Candidates...)
		r.MAC = r.signature(token)
		out.Records = append(out.Records, r)
	}
	return out
}

func (s *signalClient) exchange(ctx context.Context, endpoint string) ([]signalRecord, error) {
	data, err := json.Marshal(s.snapshot())
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(endpoint, "/")+"/v1/sync", bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Mesh-Peer", s.cfg.SelfID)
	req.Header.Set("Authorization", "Bearer "+signalToken(s.cfg.SignalingKey, s.cfg.ClusterName, s.cfg.SelfID))
	resp, err := s.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("signaling: %s", resp.Status)
	}
	var result signalExchange
	body, err := io.ReadAll(io.LimitReader(resp.Body, signalMaxBody+1))
	if err != nil {
		return nil, err
	}
	if len(body) > signalMaxBody {
		return nil, fmt.Errorf("signaling response too large")
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, err
	}
	if result.Peer != s.cfg.SelfID || len(result.Records) > 2*(len(s.cfg.Peers)-1) {
		return nil, fmt.Errorf("invalid signaling response")
	}
	return result.Records, nil
}

func (s *signalClient) accept(records []signalRecord, deliver func(signalRecord)) {
	s.applyMu.Lock()
	defer s.applyMu.Unlock()
	for _, r := range records {
		if s.cfg.peerByID(r.From) == nil || s.cfg.peerByID(r.To) == nil || r.From == r.To ||
			r.Clock == 0 || r.Clock > 1<<63 || len(r.Boot) != 32 || len(r.Candidates) > signalMaxCandidates ||
			len(r.Offer) < 4 || len(r.Offer) > 256 || (r.From < r.To && r.Offer != r.Auth[0]) ||
			len(r.Auth[0]) < 4 || len(r.Auth[0]) > 256 || len(r.Auth[1]) < 22 || len(r.Auth[1]) > 256 {
			continue
		}
		token := signalSigningKey(s.cfg.SignalingKey, s.cfg.ClusterName, r.From)
		if !hmac.Equal([]byte(r.MAC), []byte(r.signature(token))) {
			continue
		}
		s.mu.Lock()
		// Lamport receive rule applies to every authenticated record. This
		// also recovers after all brokers lost their state: surviving peers
		// carry the old clock forward in their own refreshed snapshots.
		if r.Clock > s.clock {
			s.clock = r.Clock
		}
		if r.From == s.cfg.SelfID {
			s.mu.Unlock()
			continue
		}
		if r.To != s.cfg.SelfID {
			s.mu.Unlock()
			continue
		}
		old, ok := s.remote[r.From]
		if ok && !r.newer(old) {
			s.mu.Unlock()
			continue
		}
		s.remote[r.From] = r
		s.mu.Unlock()
		deliver(r)
	}
}

func (s *signalClient) run(ctx context.Context, deliver func(signalRecord)) {
	var wg sync.WaitGroup
	for _, endpoint := range s.cfg.SignalingURLs {
		wake := make(chan struct{}, 1)
		s.mu.Lock()
		s.wake = append(s.wake, wake)
		s.mu.Unlock()
		wg.Add(1)
		go func(endpoint string) {
			defer wg.Done()
			ticker := time.NewTicker(signalRefresh)
			defer ticker.Stop()
			failed := false
			for ctx.Err() == nil {
				records, err := s.exchange(ctx, endpoint)
				if err != nil {
					if !failed && ctx.Err() == nil {
						log.Printf("signaling %s: %v", endpoint, err)
					}
					failed = true
				} else {
					if failed {
						log.Printf("signaling %s recovered", endpoint)
					}
					failed = false
					s.accept(records, deliver)
				}
				select {
				case <-ctx.Done():
					return
				case <-ticker.C:
				case <-wake:
				}
			}
		}(endpoint)
	}
	wg.Wait()
}

func parseSignalingKey(encoded string) ([]byte, error) {
	key, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil || len(key) != 32 {
		return nil, fmt.Errorf("GOSSIP_KEY must be a base64-encoded 32-byte bootstrap key")
	}
	return key, nil
}
