# Symbolic security verification

This guide is for protocol reviewers. It records the security claims checked
with Tamarin, their assumptions, and the work required before making a claim
about the complete mesh protocol.

The symbolic models cover admission authorization and shared-key signaling
authentication over unbounded sessions and symbolic messages. A separate Lean
proof covers ordered policy selection, and finite TLC models investigate
dynamic slot ownership with delayed requests. A separate unbounded Lean proof
establishes one slot per instance for a corrected no-cleanup protocol.
The signaling security model provisions two members per cluster; it abstracts
snapshot ordering and leases, which have separate state-protocol proofs.
They complement the [signaling convergence proof](../proof/README.md) and the
finite [nonce-consumption model](../admission/Admission.tla). No composition
theorem connects these specifications yet.

## Run the checks

From the repository root on Linux x86-64:

```sh
python3 protocol/security/check.py
```

Prerequisites: Python 3.12+ and `curl`. The runner downloads the pinned
[Tamarin 1.12.0](https://github.com/tamarin-prover/tamarin-prover/releases/tag/1.12.0)
and [Maude 3.5.1](https://github.com/maude-lang/Maude/releases/tag/Maude3.5.1)
archives, checks their SHA-256 hashes, and extracts them under
`$XDG_CACHE_HOME/dstack-service-mesh/` (default `~/.cache/`). The initial
downloads total about 16 MB. The extracted toolchain and host are trusted.

The runner rejects model warnings, tool errors, incomplete selected proofs,
unexpected results, changed inputs, missing fresh artifacts, and timeouts.
A scenario timeout is a failed check, never
evidence of security. Proof search has no session or trace-depth cap. Each
baseline checks every lemma; controls check their named properties only.

Logs, proof scripts, and JSON attack graphs go to `.local/protocol-security/`.
Refresh the checked-in result metadata with:

```sh
python3 protocol/security/check.py --report protocol/security/verification.json
```

Tamarin proves symbolic trace properties and can produce attack traces. Its
results rely on its proof engine and equational backend; these are separate
from Lean's kernel-checked proof terms. See the
[Tamarin introduction](https://tamarin-prover.com/manual/master/book/001_introduction.html).

## Checked claims

| Model and property | Result | Exact scope |
| --- | --- | --- |
| Admission: `grant_has_matching_evidence` | Proved | Every grant has a preceding authentic quote under a platform authority trusted by that broker, for the same complete binding, nonce, and real measurements. |
| Admission: `grant_requires_broker_local_challenge` | Proved | The nonce used for a grant was issued by that broker, even when brokers share a platform authority. |
| Admission: `shared_platform_root_reachable` | Reachable | Two distinct brokers can trust one platform signing root. Quote provenance is not assumed to be broker-exclusive. |
| Admission: `grant_matches_policy` | Proved | The identity, claimed peer, verified compose/KMS/OS measurements, and issued permission scope match a pinned row. |
| Admission: `nonce_single_grant` | Proved | A broker nonce authorizes at most one grant, despite concurrent replay. It does not limit grants across fresh nonces. |
| Admission: `honest_token_secret` | Proved conditionally | The attacker never learns a token received by an honest client over its protected channel. |
| Admission: `honest_response_authentic` | Proved conditionally | An honest client's accepted response corresponds to an earlier matching broker grant. |
| Admission: `honest_admission_reachable` | Reachable | An authorized honest client can complete admission. This is an existence witness, without a progress or latency guarantee. |
| Signaling: `record_authentic_unless_root_exposed` | Proved | An accepted MAC has a corresponding publication, unless a cluster member previously exposed the bootstrap root. |
| Signaling: `access_token_does_not_reveal_record_key` | Proved | Access-token disclosure alone does not disclose the record key for a provisioned cluster, under the ideal KDF assumption. |
| Signaling: `publication_reachable` | Reachable | Publication and acceptance can occur without a compromise. |
| Policy: `authorization_sound`, `selection_is_first_match` | Kernel-checked | Arbitrary normalized policy lists select one first matching row and materialize only that row's grants. |
| Policy: `issued_node_identity_is_confined`, `issued_agent_read_is_confined` | Kernel-checked | Self-scoped permission terms use the request's peer label and configured cluster. This does not prove physical slot ownership or Consul ACL semantics. |
| Slot allocation: `corrected_allocation_never_duplicates` | Kernel-checked | The ordered scan preserves one slot per instance under arbitrary resets and historical CAS delivery, assuming an initially empty registry without deletion/replacement. The runtime uses the reread rule; implementation refinement remains unproved. |

The admission model also proves secrecy of its ideal platform signing key as
a helper lemma. A successful runner includes expected failed stronger claims
and deliberately weakened variants. Its count is not a count of security
guarantees.

## Admission model and assumptions

[AdmissionSecurity.spthy](../admission/AdmissionSecurity.spthy) models challenge,
atomic nonce consumption, attestation verification, immutable policy matching,
token issuance, and response delivery. Nonce loss represents expiry or lost
broker state. Verification/issuance may fail after consumption; expiry does not
revoke work already accepted. Fresh symbolic nonces never collide.

The attacker can create its own client channels, submit arbitrary requests,
obtain authentic quotes from controlled runtimes, and replay messages
concurrently. A controlled runtime can choose report-data bytes while its real
measurements remain fixed. This represents access to a local attestation API,
including a compromised approved runtime; it does not assume the attacker can
modify a measurement inside signed evidence.

The symbolic abstraction has one exact-peer policy row per broker. Arbitrarily
many brokers can trust one platform root, and their public policy values may
overlap. A runtime quotes under a platform root; its quote is not addressed to
a broker. Broker-local nonce consumption supplies the challenge association.
Provisioning chooses immutable public configuration parameters, not a runtime
API through which an attacker can change an existing broker's policy.

The Tamarin profile still pins compose, KMS, and OS measurements. Multi-row
selection, wildcard peers, and optional pins are proved separately in
[AdmissionPolicy.lean](../proof/AdmissionPolicy.lean), as described in the
[Lean guide](../proof/README.md#admission-policy-authorization). No formal
semantic bridge between that selector and the Tamarin rules is claimed.
Sharing a platform authority also does not prove that brokers have consistent
policy configurations.

| Trust input | Meaning |
| --- | --- |
| Platform and verifier | An ideal signature authenticates the quote origin, real measurements, and report-data hash. Platform compromise, verifier parsing, certificate chains, TCB status, and evidence-version interpretation remain outside this model. |
| Hash and encoding | `h(<binding, nonce>)` represents collision-resistant SHA-256 over the exact binding bytes followed by a fixed 32-byte nonce. Structured binding terms assume unambiguous parsing. JSON parser equivalence is unproved. |
| Binding statement | Version, identity, cluster, peer, app, instance, claimed compose, and issued-at are all hashed. Policy uses request identity, quoted peer, and real verified measurements. Claimed metadata does not acquire independent authority by being hashed. |
| Broker and issuer | The broker enforces the configured policy. The trusted Consul issuer grants exactly the row's opaque scope. Consul ACL expansion, policy-name hashing, and authorization semantics are unproved. |
| Protected client channel | Private channel facts assume confidentiality and authenticated endpoints. Messages may be replayed or delayed indefinitely. An attacker controls its own channels but cannot read or inject into an honest client's channel. This assumption is not derived from the mesh or admission itself. |

The channel identifier is a ghost request/response association, not a new wire
field or proof of an attested client identity. The model does not equate HTTP
over the existing overlay with mutually attested TLS. In particular, QUIC's
self-signed certificate does not itself authenticate the remote workload.
Binding and nonce labels on token responses also record that request
association; the current HTTP success response carries the bearer token,
without those additional fields.

The model's quote-origin instance is a ghost label for the actual quoting
runtime. It does not assert that the current verifier returns an authenticated
instance ID to the broker.

## Counterexamples and their significance

Two stronger goals fail in the current design abstraction:

1. `individual_authentication_despite_other_member_compromise` fails in
   [SignalingAuth.spthy](../snapshots/SignalingAuth.spthy). The attacker
   compromises member A, obtains the cluster bootstrap root, derives member B's
   record key, and submits a MAC for a body B never published. B remains
   uncompromised. Individual authentication against a compromised member needs
   credentials that member A cannot derive for B.
2. `claimed_instance_is_attested_instance` fails in admission. A controlled
   runtime with allowed measurements obtains a fresh challenge, quotes a
   binding with a different claimed instance, and receives a policy-matched
   token. The broker matches peer namespace and measurements, without comparing
   the claimed instance to an independent source of instance identity. Strong
   instance or slot ownership requires that independent binding and its policy.

These confirm documented trust limits. They are not demonstrations that an
uncompromised, measured sidecar executes attacker-selected report-data requests,
nor do they establish a new production exploit.

Four controls validate the main checks:

| Removed protection | Expected counterexample |
| --- | --- |
| Atomic single-use nonce | Replaying one request produces two grants. |
| Exact report-data binding | A genuine quote for another binding or nonce authorizes the submitted request. |
| Peer-policy equality | An allowed measurement obtains a grant for an unmatched claimed peer. |
| Protected admission channel | Token secrecy fails, and a separate reachability witness requires disclosure of a genuine broker-issued token for an honest request. |

The public-channel control establishes a prerequisite for bearer-token
delivery. It does not claim that the current production route exposes those
tokens to an internet observer. Establishing that route's channel properties
is a separate proof obligation.

## Dynamic slot allocation findings

[SlotOwnership.tla](../bootstrap/SlotOwnership.tla) follows the dynamic
`claimOrdinal` scan in [bootstrap-secrets](../../components/bootstrap-secrets/main.go).
It models cached reads, atomic create-if-absent CAS, delayed server execution,
lost requests/replies, process retirement, and reboot. A reply from a retired
incarnation cannot change its replacement's local state, but its request can
still change the registry. An active incarnation includes its claim consumers;
normal completion of the bootstrap init program does not retire those consumers.

The checked bounds are two processes, two slots, and at most one reboot per
process. Each incarnation makes one ordered scan. TLC exhausts these finite
state graphs without a transition-depth constraint; this is not an unbounded
proof or an allocation-progress theorem. The runtime performs one ordered scan
and reports exhaustion when every slot belongs to another instance.

### Fixed delayed-CAS race

`UncheckedCASFailure.cfg` preserves the previous algorithm's violation of
`InstanceHasOneSlot` with atomic CAS, unique instance IDs, and no administrative
cleanup:

1. Instance A sends a CAS for empty slot 0 and retires before it commits.
2. A reboots, reads slot 0 as empty, and sends a new CAS for it.
3. The old request commits first. The new CAS fails because slot 0 now contains A.
4. The previous algorithm advances to slot 1 without rereading slot 0.
5. A's CAS for slot 1 commits. The registry now assigns both slots to A.

The first returned claim may therefore differ from the slot found on a later
scan. This was a stability/capacity defect in the dynamic allocation protocol;
it is not a demonstrated attestation bypass. The old trace is now a
`COUNTEREXAMPLE CONTROL` for the corrected algorithm.

The runtime and `SlotOwnership.cfg` reread the same slot after a failed CAS.
They can recognize their own earlier claim instead of advancing. Within the
checked bounds, with no cleanup, all reported live claims remain owned, no
two live processes alias a slot, and each instance owns at most one slot.
The runtime explicitly requests
[strongly consistent reads](https://developer.hashicorp.com/consul/api-docs/features/consistency)
to match the model's read contract. Storage errors terminate allocation. Since
records are permanent, a full registry returns an error without waiting for
slots to clear. No implementation refinement proof is claimed. The separate
[unbounded slot theorem](../proof/README.md#corrected-slot-allocation-without-cleanup)
proves one-slot-per-instance for the corrected ordered scan from an empty
registry without cleanup. It permits arbitrary resets and delivery/replay of
captured old requests; its cursor/request prefix invariants are derived from
protocol actions. It does not establish exclusive live ownership or progress,
and does not automatically refine this finite TLC specification.

The deterministic [Go regression](../../components/bootstrap-secrets/main_test.go)
commits an old request between a fresh read and CAS, then requires the allocator
to return the original slot without attempting another. It also checks foreign
ownership after a lost race, persisted-owner rejoin, concurrent distinct
claimers, storage errors, and exhaustion. Run it with:

```sh
go -C components/bootstrap-secrets test -race ./...
```

The correction prevents new duplicates from a protocol-valid registry. It does
not repair duplicate records left by the previous algorithm.

### Reuse and process-exclusivity boundaries

- `LiveCleanup.cfg` shows that deleting a live owner's record permits another
  live instance to claim the same logical slot.
- `RetiredCleanup.cfg` still violates one-slot-per-instance with the modeled
  reread correction and cleanup restricted to retired owners. A delayed
  request from A can target a slot temporarily owned by B. A's new process
  skips B's occupied slot and claims another. Deleting retired B's record then
  lets A's old request commit into the newly empty slot.
- `DuplicateInstance.cfg` shows that concurrent processes with the same
  instance ID can both report one slot, even with atomic CAS and rereading.
  Registry ownership alone does not establish exclusive process ownership.

Retiring an owner does not exclude stale requests from other incarnations.
Safe reuse needs an explicit ownership/fencing protocol that addresses both
live owners and outstanding operations. No such reuse algorithm is proved
here. The suite also checks a deliberately non-atomic-CAS control and witnesses
for successful allocation by both distinct instances and persisted-owner rejoin.

Ownership records must not be deleted or reassigned, even after their owner
retires. The runtime does not implement cleanup or fencing. Disabling reuse
does not establish exclusive live ownership for two clients sharing one
instance identifier; that remains a separate lifecycle contract.

Current Terraform deployments supply named-slot ordinals and bypass this
dynamic allocator. Named-slot replacement, provider-enforced exclusivity,
configuration authority, and KMS derivation remain separate contracts. These
TLC results do not establish those contracts.

## Roadmap for the complete protocol

Use this inventory to define the eventual verification claim. Imported
protocols still need explicit contracts at their boundaries.

| Part | Existing evidence | Remaining protocol obligations |
| --- | --- | --- |
| Leaderless signaling state | Conditional unbounded Lean convergence and safety; finite TLC checks | Connect authenticated provenance to the symbolic MAC model under one threat model. Account for failure-driven resets when claiming transport recovery. |
| Admission | Symbolic safety with shared platform authorities; kernel-checked arbitrary policy selection; finite nonce/check model | Connect policy selection to symbolic evidence/grant traces, prove cross-broker policy consistency assumptions, and establish conditional admission progress. |
| Bootstrap and node ownership | Delayed-CAS correction and deterministic runtime regression; unbounded one-slot safety for the no-cleanup scan; finite lifecycle models | Specify exclusive live ownership, fenced reuse, named-slot exclusivity, KMS isolation, and configuration authority. |
| ICE/QUIC overlay | Lifecycle/candidate models and expiry counterexamples | Establish endpoint identity, credential secrecy assumptions, allowed-port confinement, framing, and session isolation. Transport progress needs network and mapping-lifetime assumptions. |
| Consul/Connect authorization | Admission scope is an opaque issuer contract | Validate the contract for token scope, CA issuance, service identity, and proxy authorization. Treat upstream Raft, TLS, and ICE as dependencies with explicit assumptions. |
| Token and policy lifecycle | Static policy; non-expiring tokens by default | Specify renewal, revocation, policy changes, and rollback behavior before proving them. These flows are not implemented protocols yet. |
| Composition | No project-wide theorem | Prove that one layer supplies the assumptions required by the next, including bootstrap independence and bearer-token channel protection. |

The immediate open obligations are a safe reuse contract and connecting
policy authorization to attested identity and
channel authentication. Independent proofs under incompatible assumptions
would leave the meaning of an admitted peer unresolved.

A complete claim must identify the specification version, adversary, safety
and progress properties, assumptions, and imported contracts. Formal
verification cannot establish the absence of every security risk. It can
establish that the specified protocol satisfies those properties under the
stated model. Go refinement remains a separate task, as in the signaling work.

## Source correspondence

The security specifications abstract the protocol operations in:

- [Broker request handling](../../components/admission-broker/main.go):
  `handleAttest`, `reportDataHex`, `parseBindingStatement`, `NonceStore`,
  `Policy.Match`, `CheckKMS`, `CheckOSImage`, and `ConsulIssuer.IssueToken`.
- [Client request construction](../../components/admission-client/main.go):
  `admitOne`, `reportData`, and `attest`.
- [Signaling key derivation](../../components/mesh-conn/signaling.go):
  `signalDerivedKey`, `signalSigningKey`, and `signalRecord.signature`.
- [Transport trust](../../components/mesh-conn/main.go): `clientTLS` and
  `serverTLS`; [sidecar admission routing](../../components/mesh-sidecar/entrypoint.sh).
- [Dynamic bootstrap](../../components/bootstrap-secrets/main.go):
  `claimOrdinal` and the named-slot ordinal selection that bypasses it.

This mapping supports review; it is not a refinement proof. The runner hashes
the models, itself, and its proof/trace artifacts in
[verification.json](verification.json). It regenerates proofs and attack graphs
on every invocation.
