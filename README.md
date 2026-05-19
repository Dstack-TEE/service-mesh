# service-mesh

Run a cluster of TEE workloads on Phala Cloud.

A single dstack CVM gives you one verifiable machine. Most real systems
need more than one machine: a database primary and replicas, API nodes,
background workers, coordinators, failover, and private traffic between
them. This project shows how to turn several Phala Cloud CVMs into one
attested cluster.

The first example is HA PostgreSQL, but the important part is the
cluster pattern:

- Deploy multiple CVMs with Terraform.
- Give every workload a stable slot name.
- Let services call each other by name, such as `postgres-master:5432`.
- Keep service traffic private inside the mesh.
- Optionally require dstack attestation before a CVM can join the mesh
  identity layer.

You should be able to get to the first useful moment without learning
Consul, Envoy, ICE, TURN, QUIC, or Patroni internals.

## What You Will See

After `terraform apply`, you get:

- three coordinator CVMs
- three worker CVMs
- a PostgreSQL cluster managed by Patroni
- an example `webdemo` service behind the mesh
- a public HTTPS URL for `webdemo`
- a public HTTPS URL for the Consul UI

The simplest verification is external:

```bash
curl "$(terraform -chdir=cluster-example output -raw webdemo_url)/all"
```

The response is JSON showing calls fanning out from one worker to other
workers through the private service mesh. You do not need SSH for the
first check.

## Quick Start

### Prerequisites

For the normal path:

- a Phala Cloud account
- a Phala Cloud API key
- Terraform

You do not need a Docker Hub account. The example defaults to prebuilt
GHCR images published by this repository. You only need Docker if you
want to build custom images locally.

You also should not need to run your own VPS for the long-term product
path. The mesh needs a rendezvous endpoint so CVMs can find each other;
that should be provided as shared Phala Cloud infrastructure. Until that
hosted endpoint is available in your environment, the self-hosted
coordinator in [`coordinator/`](coordinator/) is the advanced fallback.

### Deploy

```bash
git clone https://github.com/Dstack-TEE/service-mesh.git
cd service-mesh/cluster-example
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
```

Set:

- `gateway_domain`
- the Phala-provided rendezvous settings, or the fallback
  `external_*` settings from a self-hosted coordinator
- image references if you are not using the defaults

Then apply:

```bash
export PHALA_CLOUD_API_KEY=phak_...
terraform init -upgrade
terraform apply
```

Use an explicit API key for the account you want billed. Do not rely on
an implicit CLI current profile for production work.

### Verify

Check the web demo from your laptop:

```bash
WEB=$(terraform output -raw webdemo_url)
curl "$WEB/hello"
curl "$WEB/all"
```

`/hello` proves the selected worker is serving. `/all` proves that the
service can call `http://webdemo:8080/hello` through the mesh and reach
other worker instances by service name.

Open the Consul UI:

```bash
terraform output -raw consul_ui
```

You should see coordinator and worker nodes, plus registered services
such as `webdemo` and the PostgreSQL service entries.

For production-profile CVMs, SSH is usually disabled. Treat external
service checks, Phala logs, Phala instance metadata, and Terraform
outputs as the default verification path. Use SSH only on dev images
when you specifically need in-CVM debugging.

## The Aha Moment

From inside a workload, the mesh feels like normal service discovery:

```text
webdemo -> http://webdemo:8080/hello
app     -> postgres-master:5432
app     -> postgres-replica:5432
```

Your app does not need to know which CVM currently hosts the service.
It does not need to know peer IPs. It does not need to implement
leader discovery. It calls a stable service name, and the sidecar routes
the request to an admitted peer.

For a single-CVM dstack app, the trust question is "is this CVM running
the code I expect?" For a cluster, the extra question is "are all peers
that join this private system also expected CVMs?" This repo is the
start of that answer: Terraform declares the workload, dstack measures
the workload, and attestation admission can check evidence before
issuing mesh identity.

## Running Your Own Service

You do not need to understand the whole mesh to add a service. The
normal workflow is:

1. Build or choose your service image.
2. Add the service container to `compose/worker.yaml`.
3. Add one service declaration in `cluster-example/cluster.tf`.
4. Call it by name from other containers.

A simple service looks like this:

```hcl
{ name = "api", port = 8080, subset = null }
```

Then other containers can call:

```text
http://api:8080
```

For services with roles, declare role-specific names. The PostgreSQL
example does this:

```hcl
{ name = "postgres-master",  port = 5432, subset = "master"  }
{ name = "postgres-replica", port = 5432, subset = "replica" }
```

The app still calls stable names. Patroni and Consul update which peer
is currently `master` or `replica`.

The platform pieces should stay generic:

- `cluster-example/cluster.tf` declares services and slots.
- `compose/worker.yaml` declares workload containers.
- `mesh-sidecar` turns those declarations into local routing,
  registration, and mesh policy.

## Attestation Admission

Attestation admission is optional for first deploys and important for
the trust story.

Enable it in `cluster-example/terraform.tfvars`:

```hcl
enable_attestation_admission = true
consul_management_token      = "<consul-acl-management-token>"
dstack_verifier_image        = "dstacktee/dstack-verifier:0.5.9"
kms                          = "phala"
```

When enabled, a worker asks for a Consul node or service token only
after producing dstack evidence. The coordinator-side broker checks the
quote through `dstack-verifier`, validates report-data binding, checks
KMS identity, and compares the claimed workload identity, peer id, and
compose hash against the Terraform-rendered policy.

For the full trust flow, see [`ATTESTATION.md`](ATTESTATION.md).

## What Is Inside

The default stack uses proven infrastructure components:

- Terraform for Phala Cloud deployment
- Consul for membership, service catalog, and service intentions
- Envoy Connect for service-to-service mTLS
- Patroni for PostgreSQL leader election and failover
- `mesh-conn` for private peer connectivity between CVMs
- dstack attestation and `dstack-verifier` for admission evidence

You do not need to operate these pieces individually for the happy path.
The Terraform and compose templates wire them together.

## Development

Validate Terraform:

```bash
terraform -chdir=cluster-example init -upgrade
terraform -chdir=cluster-example validate
```

Run Go tests for the small local modules:

```bash
(cd admission-broker && go test ./...)
(cd signaling && go test ./...)
(cd webdemo && go test ./...)
```

Some modules use Go 1.24. Run them through Docker if your host Go is
older:

```bash
docker run --rm -v "$PWD:/src" -w /src/admission-client golang:1.24 go test ./...
docker run --rm -v "$PWD:/src" -w /src/bootstrap-secrets golang:1.24 go test ./...
docker run --rm -v "$PWD:/src" -w /src/mesh-conn golang:1.24 go test ./...
```

Build the main sidecar image:

```bash
docker build -t service-mesh-mesh-sidecar-check -f mesh-sidecar/Dockerfile .
```

## More Docs

- [`ARCHITECTURE.md`](ARCHITECTURE.md): how the mesh layers work.
- [`ATTESTATION.md`](ATTESTATION.md): report data, KMS checks, verifier
  output, and verification cost.
- [`FAILOVER.md`](FAILOVER.md): failover tests and measured recovery
  times.
- [`ROBUSTNESS.md`](ROBUSTNESS.md): failure modes and mitigations.
- [`PUBLISHING.md`](PUBLISHING.md): image publishing and provenance.
- [`PROGRESS.md`](PROGRESS.md): current status and remaining work.

## Current Limits

- The easiest user experience depends on a hosted rendezvous endpoint.
  Until that is available in your environment, use the self-hosted
  coordinator fallback in [`coordinator/`](coordinator/).
- Provider `0.3.0-beta.1` supports stable named slots, but in-place
  compose/env/image updates in members mode still need the cloud
  revision redeploy endpoint wired into the provider.
- Cluster-wide Patroni and Consul bootstrap secrets are still generated
  by Terraform and stored in tfstate. The planned replacement is
  TEE-rooted secret generation and distribution.
- Broker-issued Consul tokens are currently long-lived. Short TTLs need
  explicit renewal and reload paths for Consul, Envoy, and Patroni.

## License

Apache-2.0. See [`LICENSE`](LICENSE).
