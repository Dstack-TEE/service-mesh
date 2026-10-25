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
bash support/deploy-cluster.sh clusters/patroni-demo
# Or:
bash support/deploy-cluster.sh clusters/starter
```

`TERRAFORM_BIN` can select another Terraform-compatible executable. It must
not point to a Phala Cloud CLI wrapper. Supply the provider's API credential
through its normal environment/configuration. The driver preserves
`TF_CLI_CONFIG_FILE`, including an existing local provider development
override.

The driver defaults to Terraform parallelism 10. Set `DEPLOY_PARALLELISM`
to a positive integer to change both stages. Each stage still uses one
Terraform apply and its normal state lock. Concurrent app creation requires
a cloud backend with the KMS nonce-allocation fix for issue #1544; use
`DEPLOY_PARALLELISM=1` with older backends. API quotas can limit request
throughput even while CVMs boot independently.

The driver initializes Terraform and performs three explicit stages:

1. Allocate the coordinator app without waiting for its bootstrap CVM to boot,
   and persist the returned `coordinator_app_id`.
2. Allocate coordinator instance identities without waiting for boot
   (`coordinator_wait_for_ready=false`).
3. Write their instance URLs into `signaling.auto.tfvars.json`, apply the
   full configuration with readiness enabled, then check every broker's
   protocol endpoint. Coordinator and workload boots overlap.

This breaks the Terraform dependency cycle: instance IDs only exist after
the CVMs have been created, but the peers need those IDs in their endpoint
roster. The generated file contains the app ID and URLs, not credentials. Keep it locally
alongside Terraform state. The named slots consume this allocated app ID
instead of referring to the parent resource: Terraform otherwise makes all
slot updates wait for the bootstrap environment update to finish, even when
the app ID is unchanged. All coordinator environment updates can now run
concurrently. Repeat the driver after coordinator replacement
or scaling; a replacement changes the instance URL. Ordinary workload
updates can use `terraform apply`.

### Parallel bootstrap

Both example clusters return from bootstrap creation after
the cloud accepts it, then let their `phala_app_instance` resources create and
wait for all slots concurrently. The driver temporarily disables coordinator
instance waits only for identity allocation, and enables readiness on the
coordinator app and slots for the full apply. Workloads can boot while coordinator environments update;
admission and Consul wait for infrastructure readiness at runtime.

Coordinator slots set `wait_for_identity = true`: the cloud may accept a CVM
before returning its `instance_id`. Waiting for that identity, rather than
the entire boot, makes endpoint wiring possible without fabricating an ID.
When cloud inventory has not synchronized yet, the provider reads the ID
from the host's state API. This does not change the identity or the backend.

This path requires a provider with `env_update_scope`, `wait_for_identity`, and readiness
checks when `wait_for_ready` is enabled by an update. These changes are
not in the published `0.3.0-beta.4` provider. Select a locally built provider
through Terraform's `dev_overrides` before deploying the current examples.
Workload app resources use these settings throughout; coordinator app creation
also runs asynchronously during identity allocation:

```hcl
wait_for_ready   = false
env_update_scope = "bootstrap"
```

`env_update_scope = "bootstrap"` prevents a parent environment update from
overwriting the ordinals managed by other named-slot resources. Without it,
the existing provider updates every CVM with the bootstrap environment before
Terraform restores each slot's values, causing unnecessary reboots and
temporary identity duplication. It does not change measured compose rollout
scope or disable workload admission.

The local provider also paces API requests at 180/minute per API key and base
URL within its process. `PHALA_CLOUD_REQUESTS_PER_MINUTE` selects another
positive limit for a different quota or a key shared with other tools. This
limits request starts, not concurrent CVM boots. Other processes and the
cloud's hourly quota remain outside this per-process budget.

Run the three-stage driver with that provider. Terraform waits
for CVM readiness, not application readiness; verify admission, mesh links,
and application health separately before serving traffic.

Both examples pin a verifier that coalesces concurrent AMD endorsement
fetches and reports collateral outages as HTTP 503, not an invalid quote.
Admission remains fail-closed and retries dependency failures without
restarting the mesh; invalid signatures remain permanent failures.

The driver deliberately targets coordinator identity resources in the first
two stages. Targeted Terraform warnings are expected there; stage three performs a full
apply. Review both plans. Do not pass targeting, replacement, variable
overrides, destroy options, or saved plans to this driver; edit the normal
Terraform inputs instead. Destruction remains a separate explicit command.

#### Measured cross-host deployment

A fresh eight-CVM Postgres demo on prod14 and prod15, on 2026-10-25,
completed the driver in 173 seconds versus 639 seconds for the previous
serial run. Both webdemo gateways returned successful mesh-backed replies
by 204 seconds; both Postgres replicas were streaming by 209 seconds.
These are observations from one run, not latency guarantees.

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
deployment driver during a maintenance window. It does not implement
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
