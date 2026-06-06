# Design: Attestation Admission Follow-Ups

Phase 1 admission is implemented. The shipped path is documented in
`../attestation.md` and enforced by:

- Terraform preflight-derived `compose_hash` policy.
- Terraform-declared workload identities and optional `peer_id`.
- `dstack-verifier` quote and event-log validation.
- Broker-side KMS key-provider checks.
- Optional production OS image hash checks when
  `production_profile = true`.
- Consul ACL token issuance for node, webdemo, and postgres
  identities after successful attestation.

This note tracks the remaining design work. It is intentionally about
future changes only; do not use it as the runtime operator guide.

## Remaining Work

### Token Lifecycle

Current broker-issued Consul ACL tokens do not expire by default. This
keeps the first integrated version operational because Consul agents,
Envoy, and Patroni do not yet have a coordinated token reload path.

Future work:

- Issue one active token per attested workload instance.
- Add bounded TTLs.
- Implement renewal or re-attestation before expiry.
- Verify reload paths for:
  - Consul client agent node token.
  - Envoy xDS / Connect service token.
  - Patroni Consul DCS token.

### Non-NAT Secret Distribution

The cluster still generates the **gossip key** in Terraform and
distributes it via an environment variable. This is a known workaround
because the value lives in Terraform state and is visible to whoever
runs `terraform apply`.

Precedent — the role-local secrets that used to be on this list are now
derived in-TEE by `bootstrap-secrets` and never enter Terraform state:
the Consul ACL management token (coordinators, one `app_id`) and the
Patroni superuser + replication passwords (postgres replicas, one
`app_id`). Each consumer set shares an `app_id`, so `GetKey` yields
identical bytes across the app's CVMs. See `../attestation.md`.

The gossip key is harder because it is *cross-role* — coordinators AND
workload apps need byte-identical values but have different `app_id`s,
so `GetKey` alone cannot produce it; it needs attested generation plus
distribution, not just derivation.

Future work:

- Generate the cross-role gossip key inside an attested coordinator.
- Store it in Consul KV after CAS on an initialization key.
- Gate reads on attestation-issued Consul tokens.
- Remove the Terraform `random_bytes.gossip_key` resource.

The TURN shared secret is separate. It is the NAT traversal admission
key for the current VPC-like overlay model and may remain
Terraform-distributed unless the rendezvous threat model changes.

### Upgrade Policy

Phase 1 uses a static Terraform-generated allowlist of approved
`compose_hash` values. That prevents silent admission of unapproved
revisions but does not provide long-term governance for upgrades.

Future work:

- Introduce a policy server that answers whether a workload identity
  may admit a specific `compose_hash` under a policy epoch.
- Support rollout windows where old and new compose hashes are both
  valid.
- Publish or sign policy roots so users can notice unexpected upgrade
  policy changes.
- Optionally bridge to on-chain or DAO-controlled policy storage.

### Slot / Instance Binding

`peer_id` is currently the Terraform-declared mesh node namespace, such
as `worker-3`. It is quoted in `report_data` and matched against the
policy before a scoped token is issued.

Future work:

- Bind attestation to a platform-stable slot or instance evidence field
  once Phala exposes one without creating a deployment cycle.
- Keep `compose_hash` as revision evidence, not the workload row key.

### Rendezvous Hardening

Low-level ICE rendezvous still uses the TURN HMAC / shared-secret
model. Attestation gates Consul and Connect identity, not signaling.

Future work:

- Run redundant signaling/TURN coordinators.
- Sign signaling `auth` and `candidate` messages with an
  attestation-rooted identity if the coordinator is no longer treated
  as simple untrusted transport.

## Success Criteria

- Token TTL can be enabled without breaking Consul, Envoy, or Patroni.
- Cluster-wide non-NAT secrets no longer appear in Terraform state.
- A policy epoch can admit a new compose hash without editing every
  coordinator environment variable by hand.
- A workload cannot claim another logical slot or peer identity.
- Rendezvous compromise cannot impersonate a peer when signed signaling
  is enabled.
