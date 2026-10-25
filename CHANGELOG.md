# Changelog

This changelog tracks `service-mesh` releases.

## Unreleased

### Changed

- Replace the staged deployment shell driver with `phala_cvm_env` resources.
  Allocate coordinator identities, derive broker URLs, and configure values
  in one ordinary apply, without targeted phases or a generated roster file.
  The app owns measured env keys; each environment binding owns only values.

- Run independent deployment operations concurrently using Terraform's
  parallelism (10 by default), without a workload boot barrier behind
  coordinator environment updates. Document per-slot environment ownership.
- Pin the verifier with coalesced AMD endorsement fetches and HTTP 503 for
  collateral outages, so parallel attestation does not misclassify a rate
  limit as an invalid quote and restart otherwise healthy workloads.
- Pin both examples to the tested leaderless sidecar image and pin the
  Postgres demo workloads, replacing stale or floating image references.

- Deferred ICE candidate gathering until matching peer credentials arrive,
  preventing idle NAT mappings from expiring while a peer is still booting.
- Moved signaling onto every coordinator CVM with leaderless, authenticated
  snapshot replication; broker loss no longer requires an external server
  or leader election. Derive endpoint wiring from allocated slot identities.
- Made public STUN configurable (Cloudflare by default) and removed TURN
  relay support from the mesh transport so application traffic stays direct.
- Bound ICE answers to explicit offer IDs, replacing timing-based retry
  supersession and preventing duplicate/stale broker deliveries from
  restarting healthy links.
- Switched admission evidence generation from TDX-only `GetQuote` to
  the platform-neutral `Attest` API so admission can support SEV-SNP.
- Added optional `node_id` placement for pinning every HA Postgres demo
  CVM to a specific Phala Cloud node.
- Reworked README flow around demo, concepts, verification, and starter.
- Moved image references into compose files. Terraform no longer
  replaces image placeholders.
- Added Terraform checks that reject `${...}` in compose image values.
- Replaced workload `secrets` config with `compose_env`.
- Clarified the remaining workload-aware rollout gap.

### Security

- Patroni passwords now come from in-TEE derivation, not Terraform
  state.
- Validated the experimental KMS key-provider setting on AMD SEV-SNP so
  direct app deployments bind the KMS public-key identity into MRConfig v3.

### Validation

- Verified the full eight-CVM Postgres example across prod14 and prod15,
  including direct cross-host links, workload admission, streaming replicas,
  and MRConfig v3/KMS identity preservation on bootstrap and named CVMs.

### Documentation

- Added kernel-checked Lean proofs of unbounded signaling-state convergence
  and candidate dissemination, with explicit failure/timing premises and
  executable NAT-expiry counterexamples.

- Added runnable TLA+ protocol models, bounded verification results, and
  counterexample checks for signaling, handshake coordination, attempt ownership,
  candidate replay, and admission, plus initial composed recovery safety checks.
- Added this changelog and changelog maintenance instructions.
- Added the starter architecture SVG and updated the HA Postgres SVG.
- Updated attestation and publishing docs for deterministic compose
  images.

## service-mesh v0.1.1, 2026-06-04

### Security

- Consul ACL management token now comes from in-TEE derivation, not
  Terraform state.
- The token is no longer a Terraform input or deploy-host secret.

### Validation

- Verified on real Phala Cloud with the 8-CVM HA Postgres demo.
- Verified admission, mesh traffic, Patroni HA, and no management token
  in Terraform state.

### Images

- Published GHCR images for `mesh-sidecar`, `webdemo`, `patroni`, and
  `signaling`.
- Tags: `latest`, `sha-532df17b61e90f79d17f4d3b9d98cf8b90b80917`.

### Known Limits

- Use `terraform apply -parallelism=1` until the upstream KMS nonce race
  is fixed.
- Patroni passwords and the cross-role gossip key still came from
  Terraform state at this release.

## service-mesh v0.1.0, 2026-06-01

### Added

- First tagged release of the dstack service mesh example.
- Added the HA Postgres demo.
- Added the `clusters/starter` API and worker demo.
- Reorganized the repo into `components`, `workloads`, `clusters`,
  `support`, and `docs`.

### Changed

- Pinned the Phala Terraform provider to `0.3.0-beta.4`.
- Fixed unintended instance replacement for env and compose updates.

### Validation

- Verified end to end on real Phala Cloud with the 8-CVM HA Postgres
  demo.

### Images

- Published attested GHCR images for `mesh-sidecar`, `webdemo`,
  `patroni`, and `signaling`.
- Tags: `latest`, `sha-daf8dce4d2e8e9e47960df039114fcc330ef07bf`.

### Known Limits

- Use `terraform apply -parallelism=1` until the upstream KMS nonce race
  is fixed.
