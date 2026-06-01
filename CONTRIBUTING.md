# Contributing

This project is still moving quickly. Contributions are welcome, but
changes should preserve the main design goal: a general attested service
mesh for dstack CVMs, not a collection of workload-specific shortcuts.

## Development Setup

Install:

- Terraform
- Docker
- Go 1.24 for the Go modules, or Docker for running Go 1.24 tests
- Phala Cloud credentials if you are testing real deployments

Validate the Terraform example:

```bash
terraform -chdir=clusters/patroni-demo init -upgrade
terraform -chdir=clusters/patroni-demo validate
terraform -chdir=clusters/starter init -upgrade
terraform -chdir=clusters/starter validate
```

Run local Go tests:

```bash
(cd components/admission-broker && go test ./...)
(cd components/signaling && go test ./...)
(cd workloads/webdemo && go test ./...)
```

Run Go 1.24 module tests through Docker when needed:

```bash
docker run --rm -v "$PWD:/src" -w /src/components/admission-client golang:1.24 go test ./...
docker run --rm -v "$PWD:/src" -w /src/components/bootstrap-secrets golang:1.24 go test ./...
docker run --rm -v "$PWD:/src" -w /src/components/mesh-conn golang:1.24 go test ./...
```

Build the main sidecar image:

```bash
docker build -t service-mesh-mesh-sidecar-check -f components/mesh-sidecar/Dockerfile .
```

## Pull Request Expectations

- Keep platform behavior declarative where possible. `cluster.tf` and
  compose inputs should drive service registration, Envoy listeners,
  mesh allowlists, and admission policy.
- Avoid workload-specific logic in `mesh-sidecar` and `mesh-conn`.
  Workload-specific behavior should live in the workload image or
  compose service definition.
- Do not add fallback paths that silently weaken attestation, Consul
  ACLs, TLS, or mesh admission. If a security check is optional, make
  the policy explicit.
- Update docs when changing deployment shape, trust model, image names,
  Terraform variables, or operational procedures.
- Prefer digest-pinned images for real-cluster evidence and release
  validation.

## Real-Cluster Testing

Real Phala Cloud tests should record:

- provider version
- dstack OS image
- image tags or digests
- whether `enable_attestation_admission` and `production_profile` were
  enabled
- apply, no-op plan, failover, and destroy results

Do not commit API keys, Terraform state, generated tfvars, or decrypted
secrets.
