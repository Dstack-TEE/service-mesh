# service-mesh

Attested service mesh for dstack / Phala Cloud CVMs.

This repository contains a working HA PostgreSQL deployment that runs
across dstack TEE CVMs using Terraform, Consul, Envoy Connect, Patroni,
and a QUIC-over-ICE transport. It is meant to be both a runnable example
and a starting point for teams that want private service-to-service
networking, stable Terraform-managed slots, and attestation-gated service
admission.

## What You Get

- A 3-coordinator / 3-worker Phala Cloud deployment driven by
  `terraform apply`.
- Consul server quorum, Consul clients, Envoy Connect sidecars, and
  Patroni-managed PostgreSQL.
- A userspace mesh transport for CVMs that do not have direct L3
  connectivity.
- Stable named slots through `phala_app` + `phala_app_instance` in the
  Terraform provider.
- Optional dstack attestation admission before workers receive Consul
  node and service tokens.
- CI-ready image publishing to GHCR with GitHub Build Provenance.

The included workload is HA Postgres, but the mesh plumbing is designed
to be workload-neutral. Replace Patroni with another stateful service,
declare its ports in Terraform, and keep the same Consul, Envoy, mesh,
and admission structure.

## Status

This is an active engineering project. The current code has been tested
against real Phala Cloud clusters with provider
`phala-network/phala v0.3.0-beta.1`.

Recently validated:

- Named-slot Terraform apply, no-op plan, and destroy with the public
  provider.
- Direct mesh connectivity enabled by default.
- Consul quorum, Consul clients, Envoy Connect, and Patroni failover.
- Real dstack attestation admission for worker node and service tokens.
- Production-profile OS hash checks through `dstack-verifier`.

Known gaps are tracked in [`PROGRESS.md`](PROGRESS.md). The largest
remaining items are slot-aware in-place revision rollout, stronger
secret lifecycle, longer soak testing, and upgrade policy.

## Quick Start

### 1. Prepare Images

You need four images:

- `mesh-sidecar`
- `patroni`
- `webdemo`
- `signaling`

The normal path is the GitHub Actions workflow in
[`.github/workflows/publish.yml`](.github/workflows/publish.yml), which
publishes to:

```text
ghcr.io/dstack-tee/service-mesh/mesh-sidecar
ghcr.io/dstack-tee/service-mesh/patroni
ghcr.io/dstack-tee/service-mesh/webdemo
ghcr.io/dstack-tee/service-mesh/signaling
```

For local iteration, see [`PUBLISHING.md`](PUBLISHING.md).

### 2. Start The External Coordinator

The CVMs use a small external coordinator for ICE rendezvous:

- `coturn` for STUN/TURN
- `signaling` for candidate exchange

Run it on a Linux host with a public IP:

```bash
cd coordinator
cp .env.example .env
$EDITOR .env
docker compose up -d
```

Set the public host, TURN credentials, and signaling URL in
`cluster-example/terraform.tfvars` before applying Terraform.

### 3. Deploy The Cluster

```bash
cd cluster-example
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
```

Set at least:

- `gateway_domain`
- `external_signaling_url`
- `external_coordinator_host`
- `external_turn_secret`
- image references for `mesh_sidecar_image`, `patroni_image`, and
  `webdemo_image`

Export a specific Phala Cloud API key for the account you want billed:

```bash
export PHALA_CLOUD_API_KEY=phak_...
terraform init -upgrade
terraform apply
```

Do not rely on an implicit CLI "current profile" for production work.
Use an explicit API key so a deploy cannot silently target the wrong
account.

### 4. Verify The Cluster

After `terraform apply`, the workers expose Postgres through local
Envoy upstream listeners:

```bash
psql -h postgres-master -p 5432
psql -h postgres-replica -p 5432
```

From a coordinator, Consul should show all coordinators and workers:

```bash
consul members
consul operator raft list-peers
```

For failover tests and expected recovery times, see
[`FAILOVER.md`](FAILOVER.md).

## Development

This repository is a multi-component project. Useful checks:

```bash
terraform -chdir=cluster-example init -upgrade
terraform -chdir=cluster-example validate
```

```bash
(cd admission-broker && go test ./...)
(cd signaling && go test ./...)
(cd webdemo && go test ./...)
```

Some Go modules require the same Go version used by the image build.
Run them through Docker when your host Go is older:

```bash
docker run --rm -v "$PWD:/src" -w /src/admission-client golang:1.24 go test ./...
docker run --rm -v "$PWD:/src" -w /src/bootstrap-secrets golang:1.24 go test ./...
docker run --rm -v "$PWD:/src" -w /src/mesh-conn golang:1.24 go test ./...
```

Build the main sidecar image from the repository root:

```bash
docker build -t service-mesh-mesh-sidecar-check -f mesh-sidecar/Dockerfile .
```

## Repository Map

```text
.
+-- cluster-example/      Terraform cluster definition
+-- compose/              dstack compose templates for coordinators/workers
+-- coordinator/          External coturn + signaling deployment
+-- mesh-sidecar/         Runtime sidecar image and entrypoint
+-- mesh-conn/            QUIC-over-ICE peer transport
+-- bootstrap-secrets/    dstack/KMS bootstrap helper
+-- admission-broker/     Coordinator-side attestation admission service
+-- admission-client/     Workload-side admission client
+-- patroni/              PostgreSQL + Patroni image
+-- webdemo/              Small example service behind Connect
+-- signaling/            ICE candidate exchange service
+-- design/               Longer design notes and future work
```

Core docs:

- [`ARCHITECTURE.md`](ARCHITECTURE.md) explains the mesh layers, address
  spaces, and service flow.
- [`ATTESTATION.md`](ATTESTATION.md) documents report data, evidence
  policy, KMS checks, and verifier cost.
- [`FAILOVER.md`](FAILOVER.md) covers soft kill, hard kill, disk loss,
  and measured RTO.
- [`ROBUSTNESS.md`](ROBUSTNESS.md) lists failure modes by layer.
- [`PUBLISHING.md`](PUBLISHING.md) explains image publishing and
  provenance verification.
- [`PROGRESS.md`](PROGRESS.md) tracks project state and remaining work.

## Architecture Snapshot

The cluster has three planes:

| Plane | Purpose |
|---|---|
| External coordinator | Public rendezvous for ICE candidates and STUN/TURN. It is not in the data path after direct peers connect, except when TURN relay is unavoidable. |
| Peer mesh | `mesh-conn` creates pairwise ICE connections and runs QUIC streams across them. |
| Service mesh | Consul and Envoy Connect provide discovery, mTLS, intentions, and service-level routing. |

Applications do not call peer IPs directly. They bind local ports and
call service names such as `postgres-master:5432`. The sidecar maps
those names to local Envoy upstream listeners, and Envoy reaches remote
sidecars through the peer mesh.

### Address Spaces

| Range | Meaning | Used by |
|---|---|---|
| `127.0.0.1:<port>` | Local service on this CVM. | App processes, Consul, Envoy, Patroni. |
| `127.10.0.<svc>:<port>` | Local Envoy upstream for a service name. | Application clients. |
| `127.50.0.<peer>:<port>` | Remote peer loopback reached through `mesh-conn`. | Envoy and Consul only. |

App code should only use `127.0.0.1` and service names. The
`127.50.0.0/24` peer plane is platform plumbing.

## Adapting Your Workload

Workloads are declared in `cluster-example/cluster.tf`. The important
input is `local.services`, which drives:

- Consul service names
- Envoy upstream listeners
- `/etc/hosts` aliases
- `mesh-conn` peer allowlists
- service VIP allocation

A simple Consul-blind service usually needs one entry:

```hcl
{ name = "webdemo", port = 8080, subset = null }
```

A Consul-native workload with roles can expose logical service names
through subsets. Patroni uses this pattern:

```hcl
{ name = "postgres-master",  port = 5432, subset = "master"  }
{ name = "postgres-replica", port = 5432, subset = "replica" }
```

Two entries sharing a port collapse onto one backend listener, while
Consul service resolvers choose the right subset at runtime.

Only two areas should usually be workload-specific:

- the workload image and entrypoint
- the workload service/env block in `compose/worker.yaml`

The sidecar and mesh transport should not need per-workload code.

## Attestation Admission

Set this in `cluster-example/terraform.tfvars`:

```hcl
enable_attestation_admission = true
consul_management_token      = "<consul-acl-management-token>"
dstack_verifier_image        = "dstacktee/dstack-verifier:0.5.9"
kms                          = "phala"
```

The admission broker verifies dstack evidence through
`dstack-verifier`, checks report-data binding, validates KMS identity,
and matches the claimed workload identity, peer id, and compose hash
against the Terraform-rendered policy before issuing Consul ACL tokens.

Use digest-pinned images and a versioned verifier tag for production.
The detailed trust flow is in [`ATTESTATION.md`](ATTESTATION.md).

## dstack Gateway URL Convention

Two gateway forms are used when debugging services from outside the
CVM:

| Form | Behavior |
|---|---|
| `<app-id>-<port>.<gateway-domain>` | Gateway terminates TLS and forwards plain HTTP to the CVM port. |
| `<app-id>-<port>s.<gateway-domain>` | Gateway does TLS pass-through to a backend that speaks TLS itself. |

Use the plain form for Consul HTTP, Patroni REST, and `webdemo`. Use
the `s` form only for ports where the backend already speaks TLS, such
as Envoy public mTLS listeners.

## Current Limits

- Provider `0.3.0-beta.1` supports stable named slots, but app-level
  compose/env/image changes in members mode still need the cloud
  revision redeploy endpoint wired into the provider.
- The low-level rendezvous path uses TURN HMAC today. Attestation
  gates Consul/Connect identity, not ICE signaling admission.
- Cluster-wide Patroni and Consul bootstrap secrets are still generated
  by Terraform and stored in tfstate. The planned replacement is
  TEE-rooted secret generation/distribution.
- Broker-issued Consul tokens are currently long-lived. Short TTLs need
  explicit renewal and reload paths for Consul, Envoy, and Patroni.
- Production Phala OS images disable SSH. Prod-profile validation
  should use Phala logs and APIs rather than in-CVM shell commands.

## License

Apache-2.0. See [`LICENSE`](LICENSE).
