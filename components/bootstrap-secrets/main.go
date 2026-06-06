// bootstrap-secrets — init container.
//
// One-shot. Runs to completion before any other service starts on a CVM.
// Responsibilities:
//
//   1. Use the dstack Go SDK to learn this CVM's identity (AppID,
//      InstanceID, ComposeHash) and to derive cluster-wide secrets
//      (gossip key, TURN secret, Connect-CA seed) deterministically
//      from the app's KMS-bound key. Same secrets across every
//      replica of the same phala_app, never visible to the deploy
//      host.
//
//   2. Claim a stable ordinal (0..N-1) for this CVM by reading the
//      Terraform-provided role ordinal, or by atomic-CAS-ing a slot in
//      Consul KV for dynamic non-coordinator roles. The InstanceID is
//      the slot's permanent owner so restarts re-find their own slot.
//
//   3. Write everything dependent services need to a tmpfs volume
//      shared via compose. /run/secrets/{turn,ca-seed} are
//      mode-0400 binary blobs; /run/instance/info.json carries the
//      identity + ordinal. Per-protocol ports are no longer computed
//      here — every service binds its canonical well-known port on
//      127.0.0.1 (Postgres 5432, Envoy public 21000, Consul 8500/8300/
//      8301, …) and cross-peer routing happens via mesh-conn over
//      per-peer loopback VIPs.
//
//   4. Exit 0 so compose `depends_on` with
//      `condition: service_completed_successfully` can release the
//      next services.
//
// This is the only piece that holds plaintext secret material, and
// it does so entirely inside the TEE. The deploy host never sees them.

package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	dstack "github.com/Dstack-TEE/dstack/sdk/go/dstack"
	consulapi "github.com/hashicorp/consul/api"
)

func main() {
	flag.Parse()
	cfg := loadConfig()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	// 1. Identity from dstack SDK.
	client := dstack.NewDstackClient()
	info, err := client.Info(ctx)
	if err != nil {
		log.Fatalf("dstack Info: %v", err)
	}
	log.Printf("dstack: app_id=%s instance_id=%s compose_hash=%s",
		info.AppID, info.InstanceID, shortHash(info.ComposeHash))

	// 2. Derive per-app secrets via dstack KMS.
	//
	// What's derived in-TEE is role-local material: secrets whose
	// consumers all share one app_id, so GetKey (rooted at app_id)
	// yields identical bytes across the app's replicas. The Consul
	// management token (coordinators, 2b) and the Patroni passwords
	// (postgres, 2c) are derived this way, plus the always-on turn/
	// ca-seed below.
	//
	// WORKAROUND scope note: the gossip key is NOT derived here. It is
	// CROSS-ROLE (coordinators AND workload apps need byte-identical
	// bytes), and those apps have different app_ids, so GetKey cannot
	// produce the same value for all of them. It comes from Terraform-
	// generated env instead. See cluster.tf and
	// docs/design/attestation-admission.md for the principled fix.
	//
	// What's still derived here is intentionally narrow:
	//   turn:    handed to mesh-conn for coturn auth (the actual
	//            coturn host uses an out-of-band shared secret —
	//            this is for the case where a future TEE-resident
	//            TURN allocator wants per-app HMAC material).
	//   ca-seed: reserved for a future Connect-CA-from-attestation
	//            path; not currently consumed.
	derived := []struct {
		name, path, format string
	}{
		{"turn", "dstack-mesh/turn", "hex"},
		{"ca-seed", "dstack-mesh/connect-ca", "hex"},
	}
	for _, d := range derived {
		seed, err := client.GetKey(ctx, d.path, cfg.ClusterName, "secp256k1")
		if err != nil {
			log.Fatalf("GetKey %s: %v", d.path, err)
		}
		keyBytes, err := seed.DecodeKey()
		if err != nil {
			log.Fatalf("decode %s: %v", d.path, err)
		}
		if err := writeSecretEncoded("/run/secrets/"+d.name, keyBytes, d.format); err != nil {
			log.Fatalf("write %s: %v", d.name, err)
		}
		log.Printf("derived %s (%d bytes, %s-encoded) -> /run/secrets/%s",
			d.name, len(keyBytes), d.format, d.name)
	}

	// 2b. Coordinator-only: derive the Consul ACL management token in-TEE.
	//
	// The management token is the ACL root — it mints every scoped token
	// the admission broker issues. It must be byte-identical across all
	// coordinators. In the v0.3 named-slot (MIG) model every coordinator
	// is a member of ONE phala_app, so they share an app_id and GetKey()
	// returns the same bytes on every coordinator. That makes it a
	// role-local secret we can root in the TEE instead of generating it
	// in Terraform and shipping it through plaintext state + env.
	//
	// Only coordinators derive it, and only when admission is enabled
	// (otherwise there is no ACL system to manage). Workloads never hold
	// the management token; they get attested, scoped tokens from the
	// broker. The derived value is hex (matches the prior token format
	// Consul accepts as initial_management).
	if cfg.Role == "coordinator" && os.Getenv("ADMISSION_BROKER_ENABLE") == "1" {
		seed, err := client.GetKey(ctx, "dstack-mesh/consul-management", cfg.ClusterName, "secp256k1")
		if err != nil {
			log.Fatalf("GetKey consul-management: %v", err)
		}
		keyBytes, err := seed.DecodeKey()
		if err != nil {
			log.Fatalf("decode consul-management: %v", err)
		}
		if err := writeSecretEncoded("/run/secrets/consul-management-token", keyBytes, "hex"); err != nil {
			log.Fatalf("write consul-management-token: %v", err)
		}
		log.Printf("derived consul management token (%d bytes, hex) -> /run/secrets/consul-management-token", len(keyBytes))
	}

	// 2c. Postgres-only: derive Patroni's superuser + replication
	// passwords in-TEE. Like the management token these are role-local:
	// every postgres replica is a member of one phala_app, so GetKey
	// yields identical bytes across replicas and the passwords never
	// enter Terraform state. The postgres workload requests them with
	// DERIVE_PATRONI_PASSWORDS=1 (the patroni container has no dstack
	// socket of its own, so the sidecar derives and hands them over via
	// /run/secrets). hex-encoded, matching the prior token format.
	if os.Getenv("DERIVE_PATRONI_PASSWORDS") == "1" {
		patroniSecrets := []struct{ name, path string }{
			{"patroni-superuser", "dstack-mesh/patroni-superuser"},
			{"patroni-replication", "dstack-mesh/patroni-replication"},
		}
		for _, s := range patroniSecrets {
			seed, err := client.GetKey(ctx, s.path, cfg.ClusterName, "secp256k1")
			if err != nil {
				log.Fatalf("GetKey %s: %v", s.path, err)
			}
			keyBytes, err := seed.DecodeKey()
			if err != nil {
				log.Fatalf("decode %s: %v", s.path, err)
			}
			if err := writeSecretEncoded("/run/secrets/"+s.name, keyBytes, "hex"); err != nil {
				log.Fatalf("write %s: %v", s.name, err)
			}
			log.Printf("derived %s (%d bytes, hex) -> /run/secrets/%s", s.name, len(keyBytes), s.name)
		}
	}

	// 3. Ordinal selection.
	//    Three sources, in order of preference:
	//      a. WORKLOAD_ORDINAL, WORKER_ORDINAL, or COORDINATOR_ORDINAL
	//         env (set by cluster.tf when each peer is declared as a
	//         named slot — sidesteps the Consul-bootstrap chicken-and-egg).
	//      b. Consul KV CAS (the multi-server / dynamic case once
	//         phala-cloud#243 lets us pass per-instance env to a
	//         replicas:N app).
	ordinal := 0
	switch {
	case cfg.HasWorkloadOrdinal:
		ordinal = cfg.WorkloadOrdinal
		log.Printf("ordinal from WORKLOAD_ORDINAL env: %d", ordinal)
	case cfg.WorkerOrdinal > 0:
		ordinal = cfg.WorkerOrdinal
		log.Printf("ordinal from WORKER_ORDINAL env: %d", ordinal)
	case cfg.HasCoordinatorOrdinal:
		// Coordinator ordinal can be 0 (the first coord), so we use
		// a separate "set?" flag instead of >0.
		ordinal = cfg.CoordinatorOrdinal
		log.Printf("ordinal from COORDINATOR_ORDINAL env: %d", ordinal)
	default:
		var err error
		ordinal, err = claimOrdinal(cfg, info.InstanceID)
		if err != nil {
			log.Fatalf("ordinal claim: %v", err)
		}
	}

	instance := InstanceInfo{
		InstanceID:  info.InstanceID,
		AppID:       info.AppID,
		ComposeHash: info.ComposeHash,
		ClusterName: cfg.ClusterName,
		Role:        cfg.Role,
		Ordinal:     ordinal,
	}
	if err := writeJSON("/run/instance/info.json", instance); err != nil {
		log.Fatalf("write instance info: %v", err)
	}

	log.Printf("bootstrap done: role=%s ordinal=%d", cfg.Role, ordinal)
}

// =============================================================================
// config
// =============================================================================

type Config struct {
	ClusterName           string
	Role                  string
	ConsulHTTPAddr        string // 127.0.0.1:<port> on the local agent
	ExpectedReplicas      int    // upper bound on ordinal slots to try
	WorkloadOrdinal       int    // optional, set by cluster.tf per workload slot (>=0)
	HasWorkloadOrdinal    bool   // distinguishes ordinal=0 from "unset"
	WorkerOrdinal         int    // optional, set by cluster.tf per-worker (>0)
	CoordinatorOrdinal    int    // optional, set by cluster.tf per-coordinator (>=0)
	HasCoordinatorOrdinal bool   // distinguishes ordinal=0 from "unset"
}

func loadConfig() *Config {
	cfg := &Config{
		ClusterName:      mustEnv("CLUSTER_NAME"),
		Role:             mustEnv("ROLE"),
		ConsulHTTPAddr:   os.Getenv("CONSUL_HTTP_ADDR"), // empty for coordinator
		ExpectedReplicas: 16,                            // generous upper bound
	}
	if v := os.Getenv("WORKLOAD_ORDINAL"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 0 {
			log.Fatalf("WORKLOAD_ORDINAL invalid: %q", v)
		}
		cfg.WorkloadOrdinal = n
		cfg.HasWorkloadOrdinal = true
	}
	if v := os.Getenv("WORKER_ORDINAL"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			log.Fatalf("WORKER_ORDINAL invalid: %q", v)
		}
		cfg.WorkerOrdinal = n
	}
	if v := os.Getenv("COORDINATOR_ORDINAL"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 0 {
			log.Fatalf("COORDINATOR_ORDINAL invalid: %q", v)
		}
		cfg.CoordinatorOrdinal = n
		cfg.HasCoordinatorOrdinal = true
	}
	if r := os.Getenv("EXPECTED_REPLICAS"); r != "" {
		n, err := strconv.Atoi(r)
		if err != nil || n <= 0 {
			log.Fatalf("EXPECTED_REPLICAS invalid: %v", err)
		}
		cfg.ExpectedReplicas = n
	}
	return cfg
}

func mustEnv(k string) string {
	v := os.Getenv(k)
	if v == "" {
		log.Fatalf("missing env %s", k)
	}
	return v
}

// =============================================================================
// ordinal claim — Consul KV CAS
// =============================================================================

// claimOrdinal walks slot indices 0..ExpectedReplicas-1, finds either
//
//   - a slot whose value is already this InstanceID (we're rejoining), or
//   - the lowest empty slot (CAS-claim it).
//
// First match wins. Returns the slot index. Slot ownership is
// permanent for the InstanceID's lifetime; cleanup of stale slots
// (when an instance is permanently retired) is a separate operator
// task — see the example README.
func claimOrdinal(cfg *Config, instanceID string) (int, error) {
	if cfg.ConsulHTTPAddr == "" {
		return 0, fmt.Errorf("CONSUL_HTTP_ADDR required for non-coordinator role")
	}
	cli, err := consulapi.NewClient(&consulapi.Config{
		Address: cfg.ConsulHTTPAddr,
		Scheme:  "http",
	})
	if err != nil {
		return 0, fmt.Errorf("consul client: %w", err)
	}
	kv := cli.KV()

	keyPrefix := fmt.Sprintf("cluster/%s/slots", cfg.ClusterName)

	// Retry the whole walk a few times — pollLoop racing with peers
	// could cause CAS misses; on a miss, try the next slot or restart
	// the walk.
	for attempt := 0; attempt < 20; attempt++ {
		for i := 0; i < cfg.ExpectedReplicas; i++ {
			key := fmt.Sprintf("%s/%d", keyPrefix, i)
			existing, _, err := kv.Get(key, nil)
			if err != nil {
				return 0, fmt.Errorf("kv get %s: %w", key, err)
			}
			switch {
			case existing != nil && string(existing.Value) == instanceID:
				log.Printf("rejoining slot %d (already owned)", i)
				return i, nil
			case existing == nil:
				ok, _, err := kv.CAS(&consulapi.KVPair{
					Key:         key,
					Value:       []byte(instanceID),
					ModifyIndex: 0,
				}, nil)
				if err != nil {
					return 0, fmt.Errorf("kv cas %s: %w", key, err)
				}
				if ok {
					log.Printf("claimed slot %d (fresh)", i)
					return i, nil
				}
				// CAS lost the race; some other peer claimed
				// this slot first. Try the next slot.
			default:
				// owned by another instance; skip
			}
		}
		// Exhausted slots without claiming or rejoining; either the
		// cluster is over-replicated or there's a stale slot. Sleep
		// briefly and retry — gives a slot a chance to clear if a
		// peer is in transient state.
		time.Sleep(2 * time.Second)
	}
	return 0, fmt.Errorf("no available slot in cluster %q (max=%d) — cluster over-replicated or has stale slots",
		cfg.ClusterName, cfg.ExpectedReplicas)
}

// =============================================================================
// instance info + tmpfs writes
// =============================================================================

type InstanceInfo struct {
	InstanceID  string `json:"instance_id"`
	AppID       string `json:"app_id"`
	ComposeHash string `json:"compose_hash"`
	ClusterName string `json:"cluster_name"`
	Role        string `json:"role"`
	Ordinal     int    `json:"ordinal"`
}

// writeSecretEncoded writes b to path with the given encoding. 0444
// because non-root sibling containers (coturn) need to read these;
// the trust boundary is the TEE itself, not the unix uid.
func writeSecretEncoded(path string, b []byte, format string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	switch format {
	case "raw":
		return os.WriteFile(path, b, 0o444)
	case "hex":
		return os.WriteFile(path, []byte(hex.EncodeToString(b)), 0o444)
	case "base64":
		return os.WriteFile(path, []byte(base64.StdEncoding.EncodeToString(b)), 0o444)
	default:
		return fmt.Errorf("unknown encoding %q", format)
	}
}

func writeJSON(path string, v any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(b, '\n'), 0o444)
}

func shortHash(s string) string {
	if len(s) < 12 {
		return s
	}
	return s[:12] + "..."
}

// silence unused import on Linux if go vet complains about strings
var _ = strings.HasPrefix
var _ = sha256.New
