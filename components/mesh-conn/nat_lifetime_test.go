package main

import (
	"context"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/pion/ice/v2"
	"github.com/pion/logging"
	"github.com/pion/stun"
	"github.com/pion/transport/v2/vnet"
)

// These are separate port-restricted cone NATs, not a relay. An idle mapping
// expires and the next outbound packet gets a new external port.
func newNATLifetimeNetwork(t *testing.T, lifetime time.Duration) (*vnet.Net, *vnet.Net) {
	t.Helper()
	lf := logging.NewDefaultLoggerFactory()
	wan, err := vnet.NewRouter(&vnet.RouterConfig{CIDR: "0.0.0.0/0", LoggerFactory: lf})
	if err != nil {
		t.Fatal(err)
	}
	serverNet, err := vnet.NewNet(&vnet.NetConfig{StaticIP: "1.2.3.4"})
	if err != nil {
		t.Fatal(err)
	}
	if err = wan.AddNet(serverNet); err != nil {
		t.Fatal(err)
	}
	var nets []*vnet.Net
	for _, addresses := range [][3]string{{"27.1.1.1", "192.168.0.0/24", "192.168.0.10"}, {"28.1.1.1", "10.2.0.0/24", "10.2.0.10"}} {
		lan, err := vnet.NewRouter(&vnet.RouterConfig{
			StaticIPs: []string{addresses[0]}, CIDR: addresses[1], LoggerFactory: lf,
			NATType: &vnet.NATType{MappingBehavior: vnet.EndpointIndependent,
				FilteringBehavior: vnet.EndpointAddrPortDependent, MappingLifeTime: lifetime},
		})
		if err != nil {
			t.Fatal(err)
		}
		n, err := vnet.NewNet(&vnet.NetConfig{StaticIP: addresses[2]})
		if err != nil {
			t.Fatal(err)
		}
		if err = lan.AddNet(n); err != nil {
			t.Fatal(err)
		}
		if err = wan.AddRouter(lan); err != nil {
			t.Fatal(err)
		}
		nets = append(nets, n)
	}
	if err = wan.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = wan.Stop() })
	conn, err := serverNet.ListenPacket("udp4", "1.2.3.4:3478")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	go func() {
		buf := make([]byte, 2048)
		for {
			n, addr, err := conn.ReadFrom(buf)
			if err != nil {
				return
			}
			request := &stun.Message{Raw: append([]byte(nil), buf[:n]...)}
			if request.Decode() != nil || request.Type != stun.BindingRequest {
				continue
			}
			source := addr.(*net.UDPAddr)
			reply, err := stun.Build(stun.NewTransactionIDSetter(request.TransactionID), stun.BindingSuccess,
				&stun.XORMappedAddress{IP: source.IP, Port: source.Port}, stun.Fingerprint)
			if err == nil {
				_, _ = conn.WriteTo(reply.Raw, addr)
			}
		}
	}()
	return nets[0], nets[1]
}

func gatherNATCandidates(t *testing.T, agent *ice.Agent) []ice.Candidate {
	t.Helper()
	var mu sync.Mutex
	var candidates []ice.Candidate
	done := make(chan struct{})
	if err := agent.OnCandidate(func(candidate ice.Candidate) {
		if candidate == nil {
			close(done)
			return
		}
		copy, err := ice.UnmarshalCandidate(candidate.Marshal())
		if err != nil {
			return
		}
		mu.Lock()
		candidates = append(candidates, copy)
		mu.Unlock()
	}); err != nil {
		t.Fatal(err)
	}
	if err := agent.GatherCandidates(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("candidate gathering did not complete")
	}
	mu.Lock()
	defer mu.Unlock()
	found := false
	for _, candidate := range candidates {
		found = found || candidate.Type() == ice.CandidateTypeServerReflexive
	}
	if !found {
		t.Fatal("STUN gathering produced no reflexive candidate")
	}
	return candidates
}

// A negative control demonstrates that re-publishing a descriptor does not
// refresh its NAT mapping. Gathering only after peer availability avoids the
// expired mapping without changing the transport failure timeout.
func TestNATCandidateLifetimeReproduction(t *testing.T) {
	for _, eager := range []bool{true, false} {
		name := "gather_after_peer_available"
		if eager {
			name = "eager_gather_expired_mapping"
		}
		t.Run(name, func(t *testing.T) {
			netA, netB := newNATLifetimeNetwork(t, 2*time.Second)
			url, err := stun.ParseURI("stun:1.2.3.4:3478")
			if err != nil {
				t.Fatal(err)
			}
			a, err := ice.NewAgent(&ice.AgentConfig{Net: netA, Urls: []*stun.URI{url},
				MulticastDNSMode: ice.MulticastDNSModeDisabled,
				NetworkTypes:     []ice.NetworkType{ice.NetworkTypeUDP4},
				CandidateTypes:   []ice.CandidateType{ice.CandidateTypeHost, ice.CandidateTypeServerReflexive}})
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = a.Close() })
			var ca []ice.Candidate
			if eager {
				ca = gatherNATCandidates(t, a)
			}
			time.Sleep(3 * time.Second) // Deliberately exceed the configured 2s idle NAT lifetime.
			b, err := ice.NewAgent(&ice.AgentConfig{Net: netB, Urls: []*stun.URI{url},
				MulticastDNSMode: ice.MulticastDNSModeDisabled,
				NetworkTypes:     []ice.NetworkType{ice.NetworkTypeUDP4},
				CandidateTypes:   []ice.CandidateType{ice.CandidateTypeHost, ice.CandidateTypeServerReflexive}})
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = b.Close() })
			if !eager {
				ca = gatherNATCandidates(t, a)
			}
			cb := gatherNATCandidates(t, b)
			for _, c := range ca {
				if err := b.AddRemoteCandidate(c); err != nil {
					t.Fatal(err)
				}
			}
			for _, c := range cb {
				if err := a.AddRemoteCandidate(c); err != nil {
					t.Fatal(err)
				}
			}
			ua, pa, err := a.GetLocalUserCredentials()
			if err != nil {
				t.Fatal(err)
			}
			ub, pb, err := b.GetLocalUserCredentials()
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
			defer cancel()
			result := make(chan error, 2)
			go func() { _, err := a.Dial(ctx, ub, pb); result <- err }()
			go func() { _, err := b.Accept(ctx, ua, pa); result <- err }()
			errA, errB := <-result, <-result
			if eager {
				if errA == nil || errB == nil {
					t.Fatal("negative control unexpectedly connected with an expired mapping")
				}
			} else if errA != nil || errB != nil {
				t.Fatalf("fresh candidates did not connect: %v; %v", errA, errB)
			}
		})
	}
}

// Exercise the production Mesh, snapshot broker and ICE attempt lifecycle.
// An offer can wait arbitrarily long for a peer; it must not allocate an idle
// NAT mapping during that wait. The failure budget is intentionally unchanged.
func TestStaggeredStartupGathersAfterAnswer(t *testing.T) {
	sink := captureLogs(t)
	// Mapping validity must exceed signaling delivery: this harness can take
	// two 1s polling rounds to exchange both candidate sets. A 2s mapping can
	// expire during those rounds even without an offline peer. Use 5s here
	// to isolate offline aging, then delay the peer longer than that lifetime.
	netA, netB := newNATLifetimeNetwork(t, 5*time.Second)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	broker := newTestBroker()
	t.Cleanup(broker.Close)
	a := newTestPeer(t, broker.URL(), "peer-A", twoPeers(), 21029)
	b := newTestPeer(t, broker.URL(), "peer-B", twoPeers(), 21029)
	t.Cleanup(a.stop)
	created := make(chan *ice.Agent, 1)
	trace := logging.NewDefaultLoggerFactory()
	trace.DefaultLogLevel = logging.LogLevelTrace
	trace.Writer = sink
	a.mesh.cfg.STUNURLs = []string{"stun:1.2.3.4:3478"}
	b.mesh.cfg.STUNURLs = []string{"stun:1.2.3.4:3478"}
	a.mesh.newAgent = func(cfg *ice.AgentConfig) (*ice.Agent, error) {
		cfg.Net = netA
		cfg.LoggerFactory = trace
		cfg.NetworkTypes = []ice.NetworkType{ice.NetworkTypeUDP4}
		cfg.MulticastDNSMode = ice.MulticastDNSModeDisabled
		agent, err := ice.NewAgent(cfg)
		if err == nil {
			created <- agent
		}
		return agent, err
	}
	b.mesh.newAgent = func(cfg *ice.AgentConfig) (*ice.Agent, error) {
		cfg.Net = netB
		cfg.LoggerFactory = trace
		cfg.NetworkTypes = []ice.NetworkType{ice.NetworkTypeUDP4}
		cfg.MulticastDNSMode = ice.MulticastDNSModeDisabled
		return ice.NewAgent(cfg)
	}
	a.start(ctx)
	var agent *ice.Agent
	select {
	case agent = <-created:
	case <-time.After(5 * time.Second):
		t.Fatal("initiator did not create an offer agent")
	}
	time.Sleep(6 * time.Second) // Longer than the simulated NAT's idle lifetime.
	candidates, err := agent.GetLocalCandidates()
	if err != nil {
		t.Fatal(err)
	}
	if len(candidates) != 0 {
		t.Fatalf("initiator gathered %d candidates while no answer existed; its NAT mapping can expire", len(candidates))
	}
	b.start(ctx)
	t.Cleanup(b.stop)
	elapsed, err := waitBothLinksUp(t, a, b, 5*time.Second)
	if err != nil {
		t.Fatalf("staggered NAT startup failed: %v\n%s", err, sink.String())
	}
	t.Logf("convergence after delayed peer arrival: %s", elapsed)
}
