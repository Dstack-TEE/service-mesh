# service-mesh

Build attested applications that span multiple Phala Cloud CVMs.

If you already know dstack, you know how to prove one CVM is running the
code you expect. The next step is harder: a real application usually has
several machines. You need replicas, workers, coordinators, private
traffic, failover, and a way to reject any machine that cannot prove it
belongs to the deployment.

This repo is a working template for that next step. It deploys an
attested multi-CVM cluster and gives the workloads normal service names
to call, while the platform layer handles private routing and admission.

The demo workload is HA PostgreSQL plus a small web service. The lesson
is broader: define the cluster once, deploy it to Phala Cloud, and only
admit peers whose TEE evidence matches the definition.

## Start Here

The demo is packaged as Terraform because the deployment definition is
part of the trust story. Terraform creates the CVMs, asks Phala Cloud for
the measured app definitions, and renders the policy used by admission.

You need:

- a Phala Cloud account
- a Phala Cloud API key
- Terraform

You do not need to build images for the first run. The example points to
prebuilt GHCR images from this repository. You do not need Docker unless
you want to build or modify those images.

```bash
git clone https://github.com/Dstack-TEE/service-mesh.git
cd service-mesh/cluster-example
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
```

Fill in the Phala Cloud gateway and NAT traversal bootstrap settings in
`terraform.tfvars`. The easiest first-run path should use a public demo
bootstrap service operated by Phala Cloud. That demo service should run
signaling plus STUN only. It lets CVMs exchange connection setup
messages and discover usable network paths, but it does not provide TURN
relay capacity and should not carry application traffic.

If a public demo endpoint is not available in your environment yet, use
the self-hosted coordinator in [`coordinator/`](coordinator/) and paste
its `external_*` values. Leave `external_turn_secret` empty for the
public STUN-only demo service; set it only for a self-hosted coordinator
where you intentionally enable TURN fallback.

Then deploy:

```bash
export PHALA_CLOUD_API_KEY=phak_...
terraform init -upgrade
terraform apply
```

Attestation admission is enabled by default. A worker gets its mesh
identity only after the coordinator verifies its dstack evidence against
the Terraform-rendered policy. For a first smoke test you can set
`enable_attestation_admission = false`, but that is not the intended
trust mode.

## Verify The Result

The first check should not require SSH. Terraform prints a public URL for
the demo service:

```bash
WEB=$(terraform output -raw webdemo_url)
curl "$WEB/hello"
```

That checks that one worker is serving traffic. Now ask that worker to
call the same service by its internal service name:

```bash
curl "$WEB/all"
```

The response is JSON. It should contain replies from multiple workers.
That is the short proof that:

- the public gateway reached a CVM,
- the workload called another workload by service name,
- the call traveled through the private mesh,
- the remote workload was admitted into the cluster identity layer.

You can also open the Consul UI:

```bash
terraform output -raw consul_ui
```

Use the UI to see nodes and registered services. For production-profile
CVMs, assume SSH is unavailable. Prefer public service checks, Phala
logs, Phala instance metadata, and Terraform outputs. Use SSH only on
dev images for low-level debugging.

## What The App Developer Sees

Application code does not need peer addresses or leader-election logic.
It calls stable service names:

```text
http://webdemo:8080
postgres-master:5432
postgres-replica:5432
```

In the PostgreSQL example, `postgres-master` follows the current leader
and `postgres-replica` reaches read replicas. After a failover, the app
keeps using the same names.

That is the main user-facing abstraction: a cluster of attested CVMs
behaves like a private service environment.

## Use Your Own Service

To adapt the example, start with the service you want to run, not with
the mesh internals.

For a normal stateless service:

1. Put your container in `compose/worker.yaml`.
2. Add its image variable in `cluster-example/cluster.tf`.
3. Declare the service name and port.
4. Call that name from other containers.

Example declaration:

```hcl
{ name = "api", port = 8080, subset = null }
```

Other workloads can then call:

```text
http://api:8080
```

For a role-based service, declare the role names your clients should
use. PostgreSQL uses:

```hcl
{ name = "postgres-master",  port = 5432, subset = "master"  }
{ name = "postgres-replica", port = 5432, subset = "replica" }
```

The platform sidecar turns those declarations into local routing,
service registration, and admission policy. Your service should not need
to know how peers discover each other.

## What Is Being Verified

At admission time, a worker submits dstack evidence to the coordinator.
The coordinator checks:

- the TEE quote through `dstack-verifier`,
- the report-data binding for the claimed workload identity,
- the KMS identity,
- the compose hash measured by dstack,
- the peer name claimed by the workload,
- and, when `production_profile = true`, the OS image hash.

If the evidence matches the Terraform-rendered policy, the coordinator
issues scoped Consul tokens for that node and service. If it does not
match, the workload does not get mesh identity.

See [`ATTESTATION.md`](ATTESTATION.md) for the exact report-data format,
policy fields, and verifier outputs.

## What Is Under The Hood

You can use the template without operating each layer manually. When you
need the details, the implementation uses:

- Terraform for Phala Cloud deployment and policy rendering,
- Consul for membership and service catalog,
- Envoy Connect for service-to-service mTLS,
- Patroni for PostgreSQL failover in the example workload,
- a small peer transport for private CVM-to-CVM connectivity,
- dstack attestation plus `dstack-verifier` for admission evidence.

The detailed architecture is in [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Development

Validate Terraform:

```bash
terraform -chdir=cluster-example init -upgrade
terraform -chdir=cluster-example validate
```

Run local Go tests:

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

Build the sidecar image:

```bash
docker build -t service-mesh-mesh-sidecar-check -f mesh-sidecar/Dockerfile .
```

## More Docs

- [`ATTESTATION.md`](ATTESTATION.md): trust flow, report data, KMS
  checks, and verifier cost.
- [`ARCHITECTURE.md`](ARCHITECTURE.md): mesh layers and request flow.
- [`FAILOVER.md`](FAILOVER.md): failover tests and measured recovery
  times.
- [`ROBUSTNESS.md`](ROBUSTNESS.md): failure modes and mitigations.
- [`PUBLISHING.md`](PUBLISHING.md): image publishing and provenance.
- [`PROGRESS.md`](PROGRESS.md): current status and remaining work.

## Current Limits

- The easiest user experience depends on a hosted NAT traversal
  bootstrap endpoint. The public demo endpoint should be STUN-only; TURN
  relay is a self-hosted or future credentialed service.
  Until that is available in your environment, use the self-hosted
  coordinator fallback in [`coordinator/`](coordinator/).
- Provider `0.3.0-beta.1` supports stable instance management, but
  in-place compose/env/image updates still need the cloud revision
  redeploy endpoint wired into the provider.
- Cluster-wide Patroni and Consul bootstrap secrets are still generated
  by Terraform and stored in tfstate. The planned replacement is
  TEE-rooted secret generation and distribution.
- Broker-issued Consul tokens are currently long-lived. Short TTLs need
  explicit renewal and reload paths for Consul, Envoy, and Patroni.

## License

Apache-2.0. See [`LICENSE`](LICENSE).
