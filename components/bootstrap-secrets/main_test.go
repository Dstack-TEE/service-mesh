package main

import (
	"encoding/json"
	"fmt"
	"io"
	"maps"
	"net/http"
	"net/http/httptest"
	"reflect"
	"slices"
	"strings"
	"sync"
	"testing"

	consulapi "github.com/hashicorp/consul/api"
)

// slotRegistry implements the Consul operations used by claimOrdinal. The
// delayedOwner hook commits an earlier caller's request just before the first
// CAS is evaluated, without relying on process timing or sleeps.
type slotRegistry struct {
	mu           sync.Mutex
	owners       map[string]string
	delayedOwner string
	requests     []string
	failMethod   string
}

func (r *slotRegistry) serveHTTP(w http.ResponseWriter, req *http.Request) {
	r.mu.Lock()
	defer r.mu.Unlock()
	key := strings.TrimPrefix(req.URL.Path, "/v1/kv/")
	r.requests = append(r.requests, req.Method+" "+key)
	if req.Method == r.failMethod {
		http.Error(w, "registry unavailable", http.StatusServiceUnavailable)
		return
	}
	switch req.Method {
	case http.MethodGet:
		if !req.URL.Query().Has("consistent") {
			http.Error(w, "expected strongly consistent read", http.StatusBadRequest)
			return
		}
		owner, exists := r.owners[key]
		if !exists {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		_ = json.NewEncoder(w).Encode([]*consulapi.KVPair{{Key: key, Value: []byte(owner), ModifyIndex: 1}})
	case http.MethodPut:
		if req.URL.Query().Get("cas") != "0" {
			http.Error(w, "expected create-if-absent CAS", http.StatusBadRequest)
			return
		}
		body, err := io.ReadAll(req.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if r.delayedOwner != "" {
			r.owners[key] = r.delayedOwner
			r.delayedOwner = ""
		}
		_, exists := r.owners[key]
		if !exists {
			r.owners[key] = string(body)
		}
		_ = json.NewEncoder(w).Encode(!exists)
	default:
		http.Error(w, "unexpected method", http.StatusMethodNotAllowed)
	}
}

func (r *slotRegistry) snapshot() (map[string]string, []string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return maps.Clone(r.owners), slices.Clone(r.requests)
}

func TestClaimOrdinalDelayedCAS(t *testing.T) {
	for _, tc := range []struct {
		name         string
		delayedOwner string
		wantOrdinal  int
		wantRequests []string
	}{
		{
			name:         "old incarnation claims for this instance",
			delayedOwner: "this-instance",
			wantOrdinal:  0,
			wantRequests: []string{"GET cluster/test/slots/0", "PUT cluster/test/slots/0", "GET cluster/test/slots/0"},
		},
		{
			name:         "another instance claims the slot",
			delayedOwner: "other-instance",
			wantOrdinal:  1,
			wantRequests: []string{"GET cluster/test/slots/0", "PUT cluster/test/slots/0", "GET cluster/test/slots/0", "GET cluster/test/slots/1", "PUT cluster/test/slots/1"},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			registry := &slotRegistry{owners: make(map[string]string), delayedOwner: tc.delayedOwner}
			server := httptest.NewServer(http.HandlerFunc(registry.serveHTTP))
			defer server.Close()
			ordinal, err := claimOrdinal(&Config{ClusterName: "test", ConsulHTTPAddr: server.URL, ExpectedReplicas: 2}, "this-instance")
			if err != nil {
				t.Fatal(err)
			}
			owners, requests := registry.snapshot()
			if ordinal != tc.wantOrdinal {
				t.Fatalf("ordinal = %d, want %d; registry = %v", ordinal, tc.wantOrdinal, owners)
			}
			if !reflect.DeepEqual(requests, tc.wantRequests) {
				t.Fatalf("requests = %v, want %v", requests, tc.wantRequests)
			}
		})
	}
}

func TestClaimOrdinalRejoinsPermanentSlot(t *testing.T) {
	registry := &slotRegistry{owners: map[string]string{"cluster/test/slots/0": "other-instance", "cluster/test/slots/1": "this-instance"}}
	server := httptest.NewServer(http.HandlerFunc(registry.serveHTTP))
	defer server.Close()
	ordinal, err := claimOrdinal(&Config{ClusterName: "test", ConsulHTTPAddr: server.URL, ExpectedReplicas: 2}, "this-instance")
	if err != nil || ordinal != 1 {
		t.Fatalf("claimOrdinal = (%d, %v), want (1, nil)", ordinal, err)
	}
	_, requests := registry.snapshot()
	if len(requests) != 2 {
		t.Fatalf("rejoining must only read the registry, got %v", requests)
	}
}

func TestClaimOrdinalFullRegistry(t *testing.T) {
	registry := &slotRegistry{owners: map[string]string{"cluster/test/slots/0": "other-instance", "cluster/test/slots/1": "another-instance"}}
	server := httptest.NewServer(http.HandlerFunc(registry.serveHTTP))
	defer server.Close()
	_, err := claimOrdinal(&Config{ClusterName: "test", ConsulHTTPAddr: server.URL, ExpectedReplicas: 2}, "this-instance")
	if err == nil || !strings.Contains(err.Error(), "no available slot") {
		t.Fatalf("expected exhausted registry error, got %v", err)
	}
	_, requests := registry.snapshot()
	if len(requests) != 2 {
		t.Fatalf("permanent ownership cannot clear on a retry, got %v", requests)
	}
}

func TestClaimOrdinalRegistryErrors(t *testing.T) {
	for _, method := range []string{http.MethodGet, http.MethodPut} {
		t.Run(method, func(t *testing.T) {
			registry := &slotRegistry{owners: make(map[string]string), failMethod: method}
			server := httptest.NewServer(http.HandlerFunc(registry.serveHTTP))
			defer server.Close()
			_, err := claimOrdinal(&Config{ClusterName: "test", ConsulHTTPAddr: server.URL, ExpectedReplicas: 2}, "this-instance")
			if err == nil || !strings.Contains(err.Error(), "registry unavailable") {
				t.Fatalf("expected registry error, got %v", err)
			}
			_, requests := registry.snapshot()
			if len(requests) > 2 {
				t.Fatalf("storage errors must terminate the claim, got %v", requests)
			}
		})
	}
}

func TestClaimOrdinalConcurrentInstances(t *testing.T) {
	const replicas = 8
	registry := &slotRegistry{owners: make(map[string]string)}
	server := httptest.NewServer(http.HandlerFunc(registry.serveHTTP))
	defer server.Close()
	cfg := &Config{ClusterName: "test", ConsulHTTPAddr: server.URL, ExpectedReplicas: replicas}
	type result struct {
		instance string
		ordinal  int
		err      error
	}
	start := make(chan struct{})
	results := make(chan result, replicas)
	for i := 0; i < replicas; i++ {
		go func() {
			<-start
			instance := fmt.Sprintf("instance-%d", i)
			ordinal, err := claimOrdinal(cfg, instance)
			results <- result{instance, ordinal, err}
		}()
	}
	close(start)
	claims := make(map[int]string)
	for i := 0; i < replicas; i++ {
		claim := <-results
		if claim.err != nil {
			t.Error(claim.err)
			continue
		}
		if previous, exists := claims[claim.ordinal]; exists {
			t.Errorf("instances %s and %s both claimed %d", previous, claim.instance, claim.ordinal)
		}
		claims[claim.ordinal] = claim.instance
	}
	owners, _ := registry.snapshot()
	for ordinal, instance := range claims {
		if got := owners[fmt.Sprintf("cluster/test/slots/%d", ordinal)]; got != instance {
			t.Errorf("slot %d owner = %q, want %q", ordinal, got, instance)
		}
	}
}
