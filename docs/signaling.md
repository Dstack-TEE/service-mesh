# Leaderless signaling

Every coordinator CVM runs an independent rendezvous broker inside
`mesh-conn`, on host TCP port 7000. Brokers start without Consul quorum,
mesh connectivity, or mesh-issued credentials. No external server or
separate signaling CVM is required.

Peers exchange setup state through the brokers' instance-pinned HTTPS
endpoints. Application traffic travels over direct ICE/QUIC connections,
not through the brokers. STUN is separate and configurable:

```hcl
stun_urls = ["stun:stun.cloudflare.com:3478"]
```

An empty list gathers host candidates only. TURN URLs and relay candidates
are rejected. Direct connectivity is not possible through every NAT or
firewall; unsupported paths fail rather than selecting a relay.

## Deploy

Build and publish the updated `components/mesh-sidecar/Dockerfile`, then
pin that image's digest in **every** cluster compose file before using this
unreleased protocol. Existing published images do not gain the protocol
just because Terraform configuration has changed.

From the repository root:

```bash
terraform -chdir=clusters/patroni-demo init
terraform -chdir=clusters/patroni-demo apply
# Or use clusters/starter.
```

Use a provider build that includes `phala_cvm_env`, allowlist-only
`phala_app.env_keys`, and `wait_for_identity`. These features are not in
the examples' published `0.3.0-beta.4` version constraint; select the local
provider through Terraform's `dev_overrides` until a release is available.
Supply credentials through the provider's normal configuration.

### Parallel bootstrap

Terraform now expresses the bootstrap dependencies directly in one apply:

Both examples use [`modules/mesh-coordinators`](../modules/mesh-coordinators/README.md).
Put shared values in its `env` input and per-slot values in `instances[name].env`.
The module owns `SIGNALING_URLS_JSON`; callers never feed its outputs back into
its inputs. Internally:

1. `module.coordinators.phala_app.this` creates the bootstrap CVM with its measured
   environment-key allowlist, without owning runtime values or waiting for boot.
2. `module.coordinators.phala_app_instance.this` adopts the bootstrap slot and allocates
   the other named slots. `wait_for_identity = true` obtains their real
   instance-pinned endpoint identities without requiring running workloads.
3. `module.coordinators.phala_cvm_env.this` configures each coordinator's complete
   environment map, including the derived broker roster, then waits for CVM
   readiness. Workload app creation depends on the identities, not these
   environment updates, so independent boots and updates overlap.

There is no shell driver, targeted apply, or generated roster file. Coordinator
replacement and scaling update the URLs through normal Terraform references.
Each environment resource includes the adopted bootstrap CVM; app and instance
allocation resources do not also own its values. The app retains ownership of
the measured allowlist. The environment resource validates keys and sends only
an encrypted value payload, preserving v3/KMS measurements and unknown compose
fields. A value change can still reboot its CVM through the Cloud API.

The provider waits for an existing operation on the target CVM to finish
before submitting an environment update. Independent targets remain concurrent.
Cloud does not expose plaintext environment values for readback, so this
resource cannot detect external value edits. Protect Terraform state, which
contains the configured plaintext values. Removing an environment resource
releases ownership without erasing the CVM's values; apply `env = {}` explicitly
to clear a retained CVM.

The default Terraform parallelism is 10. Use `terraform apply -parallelism=N`
to change it. Concurrent app creation requires a backend with the KMS
nonce-allocation fix for issue #1544. API request starts are paced at
180/minute per key/base URL within the provider process; aliases share the
budget. `PHALA_CLOUD_REQUESTS_PER_MINUTE` changes that limit. Responses and
CVM boots remain concurrent; other processes and the Cloud's hourly quota
remain outside this budget.

Workload apps still use `env_update_scope = "bootstrap"` when their named
instance resources own the other slots' inline environments. This prevents a
parent value update from overwriting slot-specific ordinals; compose revisions
continue to roll out app-wide.

Terraform readiness means the CVM is running with no operation in progress,
not that admission, broker compatibility, mesh links, or application health has
passed. Verify those separately before serving traffic. The pinned verifier
coalesces AMD collateral downloads and reports outages as HTTP 503; admission
remains fail-closed.

### Migrate from the staged driver

Back up state and review the plan. Use the new provider, remove the generated
`signaling.auto.tfvars.json` from the active Terraform configuration directory,
and remove any manually configured `signaling_urls`, `coordinator_app_id`, or
`coordinator_wait_for_ready` inputs. Keep resource addresses and placement
unchanged. The updated examples replace coordinator inline values with the
same allowlist and add one environment binding per existing CVM. The provider
relinquishes inline value ownership without clearing the payload. Expect
in-place configuration updates, not CVM replacement. This is not a rolling
application-upgrade mechanism.

The examples also include `moved` blocks from the former flat coordinator
resources into `module.coordinators`. Keep them, preserve names and placement,
and run `terraform init` to load the local module before planning. Existing
environment bindings move too; deployments from the staged driver create
those bindings for the first time. Do not use `state rm` to perform this move.

### Prior cross-host validation

A fresh eight-CVM Postgres demo on prod14 and prod15, on 2026-10-25,
using the previous staged driver completed in 173 seconds versus 639 seconds
for the previous serial run. Both webdemo gateways returned successful mesh-backed replies
by 204 seconds; both Postgres replicas were streaming by 209 seconds.
These are observations from the staged deployment, not a benchmark of the new
single-apply path or latency guarantees.

All 28 direct peer links connected, including 16 cross-host pairs, without
an ICE failure. The longest observed checking-to-connected interval was
three seconds despite a 104-second spread in configured mesh start times.
The test also checked all eight v3 manifests and KMS identities, 1,024
mesh-backed application calls, and a no-change Terraform plan. Postgres
roles and WAL streaming were checked through container logs; an independent
SQL write/read workload was not run.

The remaining startup time includes cloud create-operation completion and
coordinator reboots when installing the roster. Those operations now overlap;
parallel provisioning does not eliminate their individual boot times.

## Upgrade an existing cluster

This is a breaking wire-protocol change. Old mailbox clients cannot talk to
snapshot brokers. Back up application data, pin the updated sidecar image
everywhere, remove the three `external_*` bootstrap inputs, and run the
normal Terraform apply during a maintenance window. It does not implement
workload draining or a zero-downtime mixed-version upgrade.

## Protocol and recovery

`POST /v1/sync` publishes complete per-pair snapshots and returns snapshots
addressed to the authenticated peer, plus its own previous snapshots.
Reading does not drain state. There is no broker-to-broker replication,
leader election, quorum, or durable signaling database.

Each snapshot contains sender, recipient, random process incarnation,
Lamport clock, offer ID, ICE credentials, the complete candidate list,
and a message authentication code. A broker keeps only the highest
`(clock, incarnation)` version for each provisioned sender/recipient pair.
Records expire two minutes after their last strictly newer publication.
Clients refresh every second and on local state changes. Each endpoint has
its own worker and five-second HTTP timeout, so one slow broker does not
block a healthy one.

Clients apply the Lamport receive rule to authenticated records, including
their own old incarnation. This recovers ordering after a peer restart.
If all brokers lost state, surviving peers carry the clock forward in
their refreshed snapshots. No wall-clock ordering or persistent counter is
required. Concurrent live processes claiming the same logical peer ID are
not supported; Terraform slot ownership must remain unique.

For each pair, the lower peer ID initiates an ICE offer. Its ufrag identifies
the offer; the responder's answer must echo that exact ID. Stale answers
cannot affect a newer offer. Candidate lists belong to their snapshot's
credentials. Duplicate snapshots do not reset candidates, allocate another
ICE agent, or restart a healthy link. A genuine changed offer/answer
invalidates the superseded connection attempt without timing heuristics.

Credentials are published before gathering candidates. The initiator waits
for an answer to its exact offer before allocating NAT mappings; the responder
already has the offer when it gathers. This prevents a long peer boot from
aging the initiator's server-reflexive candidates before checks can start.
It does not shorten the ICE failure budget or guarantee a connection deadline:
mapping validity, timely signaling, packet delivery, and scheduling still
constrain transport progress. Repeating a snapshot refreshes broker state,
not the NAT mapping described by its candidates.

Losing brokers cannot interrupt established direct links between surviving
peers. New connections require at least one broker reachable by both ends.
After a broker restart, periodic publication reconstructs its state. Lost
HTTP responses do not lose a drained queue: the next sync reads the state
again. If all peers and brokers restart, they negotiate fresh sessions.

With `B` brokers, publication and polling work grows approximately by `B`;
full snapshots also cost more than incremental candidate messages. This is
control-plane overhead only. Broker memory is bounded by provisioned peer
pairs, candidate limits, and request-size limits, not an unbounded mailbox.

## Security boundary

Access tokens and record-MAC keys are separately domain-separated HMAC
derivations of the existing cluster bootstrap gossip key. Tokens are scoped
to cluster and peer. Brokers validate provisioned membership, sender and
recipient, signatures, record sizes, and direct-only candidates. Requests
are bounded to 1 MiB, with per-peer rate limits and server timeouts.
Clients require HTTPS except for explicit loopback test endpoints and do
not follow HTTP redirects carrying credentials.

This is **shared-key bootstrap authentication**, not attested individual
peer identity. Anyone holding the cluster bootstrap key can impersonate
another cluster peer. The existing Terraform-generated gossip key still
lives in Terraform state; protect that state. Signaling grants no Consul
or application authorization: attestation admission and Connect mTLS remain
separate requirements.

Gateway-terminated HTTPS protects the public hop but does not hide signaling
metadata or ICE credentials from that gateway. Separate record keys prevent
an observer of a bearer access token alone from forging signed snapshots.
Coordinators holding the bootstrap root remain trusted for signaling.

`components/signaling` and `support/bootstrap-coordinator` are legacy
connectivity diagnostics, not deployment dependencies. Their old mailbox
protocol is incompatible with this transport.
