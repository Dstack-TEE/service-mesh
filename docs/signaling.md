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

The driver initializes Terraform and performs two explicit stages:

1. Provision the coordinator CVMs, each already serving its broker. A fresh
   coordinator can wait for signaling while its broker remains reachable.
2. Check each broker's protocol endpoint, write its instance URL into
   `signaling.auto.tfvars.json`, and apply the full configuration.

This breaks the Terraform dependency cycle: instance IDs only exist after
the CVMs have been created, but the peers need those IDs in their endpoint
roster. The generated file contains URLs, not credentials. Keep it locally
alongside Terraform state. Repeat the driver after coordinator replacement
or scaling; a replacement changes the instance URL. Ordinary workload
updates can use `terraform apply -parallelism=1`.

The driver deliberately targets coordinators in stage one. A targeted
Terraform warning is expected there; stage two always performs a full
apply. Review both plans. Do not pass targeting, replacement, variable
overrides, destroy options, or saved plans to this driver; edit the normal
Terraform inputs instead. Destruction remains a separate explicit command.

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
