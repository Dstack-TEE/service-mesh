# service-mesh

Build an attested cluster, not just one attested VM.

If you can already deploy one dstack Confidential VM (CVM) on Phala
Cloud, the next question is: how do you run a real application made of
several CVMs, while still knowing that every machine belongs to the
deployment?

This repository is a working template for that problem. It deploys a
multi-CVM application where each node must prove its attestation
evidence before it receives credentials to join the service layer. Once
admitted, workloads call each other by normal service names.

The demo application is HA PostgreSQL plus a small web service. The
pattern is the important part: define the cluster, deploy it, verify the
running services, then replace the demo workload with your own.

## What You Get

The example deploys:

- multiple Phala Cloud CVMs managed as one application cluster,
- private service-to-service traffic between those CVMs,
- attestation-based admission for cluster members,
- stable service names such as `postgres-master` and `webdemo`,
- a public URL you can use to verify the deployment from your laptop.

You do not need to understand the internal networking stack to use the
template.

## Try The Demo

You need:

- a Phala Cloud account,
- a Phala Cloud API key,
- Terraform.

You do not need Docker for the first run. The demo uses prebuilt images
published by this repository.

The CVMs also need a connection bootstrap endpoint: a small public
service that helps them find a network path to each other during
startup. For the easiest demo path, use the public Phala-provided
bootstrap endpoint for this project. If that endpoint is not available
in your environment yet, use the self-hosted fallback in
[`coordinator/`](coordinator/).

```bash
git clone https://github.com/Dstack-TEE/service-mesh.git
cd service-mesh/cluster-example
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
```

Fill in:

- `gateway_domain`,
- the connection bootstrap values provided by Phala, or the `external_*`
  values from the self-hosted fallback,
- image values only if you are not using the defaults.

Deploy:

```bash
export PHALA_CLOUD_API_KEY=phak_...
terraform init -upgrade
terraform apply
```

Attestation admission is enabled by default. The cluster does not issue
service credentials to a worker until its dstack evidence matches the
Terraform-rendered policy.

## Verify It Works

After deployment, Terraform prints `webdemo_url`. Use it from your
laptop:

```bash
WEB=$(terraform output -raw webdemo_url)
curl "$WEB/hello"
```

That checks that the public demo service is reachable.

Now ask that service to call other demo instances through the private
cluster network:

```bash
curl "$WEB/all"
```

The response is JSON. You should see replies from multiple workers. That
proves the important path:

- your request reached the deployed app,
- one workload called another workload by service name,
- the call stayed on the private cluster network,
- the responding workload had been admitted into the cluster.

## What App Code Looks Like

Inside the cluster, application code calls service names:

```text
http://webdemo:8080
postgres-master:5432
postgres-replica:5432
```

Your app does not need to know which CVM currently hosts a service. In
the PostgreSQL demo, `postgres-master` follows the current leader and
`postgres-replica` reaches read replicas. After failover, clients keep
using the same names.

## Bring Your Own Service

To adapt the template, start from your container:

1. Add your container to `compose/worker.yaml`.
2. Add its image variable in `cluster-example/cluster.tf`.
3. Declare the service name and port.
4. Call that service name from other containers.

For a stateless service:

```hcl
{ name = "api", port = 8080, subset = null }
```

Other workloads can then call:

```text
http://api:8080
```

For a service with roles, declare the names clients should use. The
PostgreSQL demo uses:

```hcl
{ name = "postgres-master",  port = 5432, subset = "master"  }
{ name = "postgres-replica", port = 5432, subset = "replica" }
```

The platform layer turns those declarations into routing, service
registration, and admission policy.

## What Is Verified

When a worker joins, it submits dstack evidence to the coordinator: the
part of the cluster that decides whether a node can receive service
identity. The coordinator checks that evidence against the policy
generated from the Terraform deployment definition.

The policy checks include:

- the TEE quote, which proves the CVM is running under the expected
  trusted execution environment,
- the claimed workload identity,
- the measured compose hash, which identifies the app definition dstack
  measured,
- the KMS identity, which identifies the key service used by the CVM,
- the claimed peer name,
- the OS image hash when `production_profile = true`.

If the evidence matches, the worker receives scoped service identity. If
it does not match, it cannot join the service layer.

See [`ATTESTATION.md`](ATTESTATION.md) for the exact evidence format and
verification flow.

## How It Works

The first-run path hides the internals, but the implementation uses
standard infrastructure:

- Terraform for deployment and policy rendering,
- Consul for membership and service catalog,
- Envoy for service-to-service mutual TLS,
- Patroni for PostgreSQL failover in the demo workload,
- dstack attestation and `dstack-verifier` for evidence checks,
- a small peer transport so CVMs can talk privately across the provider
  network.

Read [`ARCHITECTURE.md`](ARCHITECTURE.md) when you want the lower-level
design.

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

- [`ATTESTATION.md`](ATTESTATION.md): trust flow and evidence checks.
- [`ARCHITECTURE.md`](ARCHITECTURE.md): lower-level network and service
  design.
- [`FAILOVER.md`](FAILOVER.md): failover tests and measured recovery
  times.
- [`ROBUSTNESS.md`](ROBUSTNESS.md): failure modes and mitigations.
- [`PUBLISHING.md`](PUBLISHING.md): image publishing and provenance.
- [`PROGRESS.md`](PROGRESS.md): current status and remaining work.

## Current Limits

- The smoothest first-run experience depends on a public Phala-provided
  connection bootstrap endpoint. Until that endpoint is available in
  your environment, use the self-hosted fallback in
  [`coordinator/`](coordinator/).
- The current Terraform provider can add or remove instances without
  disturbing the rest of the cluster, but in-place workload updates are
  still waiting on cloud revision rollout support.
- Cluster-wide PostgreSQL and service-layer bootstrap secrets are still
  generated by Terraform and stored in the Terraform state file. The
  planned replacement is secret generation and distribution inside
  attested CVMs.
- Broker-issued service tokens are currently long-lived. Short TTLs need
  explicit renewal and reload paths.

## License

Apache-2.0. See [`LICENSE`](LICENSE).
