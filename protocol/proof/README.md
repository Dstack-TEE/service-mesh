# Protocol proofs

[Signaling.lean](Signaling.lean) proves safety and conditional convergence of the
leaderless signaling state protocol over unbounded traces.
[AdmissionPolicy.lean](AdmissionPolicy.lean) proves authorization properties for
arbitrary normalized policy lists. [SlotAllocation.lean](SlotAllocation.lean)
proves one-slot-per-instance safety for the corrected no-cleanup allocator over
unbounded executions. These are independent specifications; no
composition theorem between them is claimed. Lean checks their proof terms
separately from the finite TLA+ model checks.

Run from the repository root on Linux x86-64:

```sh
python3 protocol/proof/check.py
```

Prerequisites: Python 3.11+, `curl`, GNU `tar`, and `zstd`. The runner downloads the
pinned [Lean 4.35.0 release](https://github.com/leanprover/lean4/releases/tag/v4.35.0),
verifies its archive SHA-256, and extracts it under
`$XDG_CACHE_HOME/dstack-service-mesh/lean4/4.35.0/` (default `~/.cache/`). The first
run needs a 567 MiB download and about 3 GiB for the toolchain. An offline
`LEAN4_ARCHIVE` can supply the same checksum-verified archive. The extracted
cache, like the local operating system, is trusted.

The checker compiles a fresh copy of each source with warnings treated as errors,
then asks Lean to print the axiom dependencies of every authored theorem and
definition. It rejects placeholders, unreviewed imports, custom axioms, and
missing audit results. Each proof imports only Lean's pinned `Std` library;
none uses Mathlib or an external solver. The permitted logical foundations
are Lean's standard `propext`, `Classical.choice`, and `Quot.sound`.

Logs go to `.local/protocol-proof/`. Refresh the checked-in evidence with:

```sh
python3 protocol/proof/check.py --report protocol/proof/verification.json
```

The evidence report uses schema version 2: `proofs` records each source, hash,
declaration count, and axiom audit. The top-level count is their total. The
runner rejects an unlisted Lean source or inputs changed during verification.

## Signaling proof

### Proven statement

`signaling_and_candidates_converge` composes the storage, client, controller,
and candidate rules. For each peer pair, under the assumptions below:

- The initiator's offer eventually becomes constant.
- The responder eventually holds one positive answer for that offer.
- Both receivers eventually retain snapshots with those same credentials.
- Every candidate gathered after that stable suffix is eventually present in
  the other receiver's retained snapshot, with the correct offer and auth.

The theorem quantifies over arbitrary natural-number clocks, publication counts,
execution lengths, and credential generations. It has no TLC counter cap, retry
budget, fixed broker count, or bound on the number of pre-stability failures.
`finite_mesh_converges` lifts per-pair convergence to any finite deployment;
`eventually_finite` also combines any finite collection of candidate deliveries.
The state machines are independent per directed peer pair. This composition
assumes their fair scheduling and capacity obligations hold together.

Safety lemmas establish authenticated provenance, lexicographic version
retention, exact offer binding, candidate epoch isolation, retention within an
epoch, and idempotent snapshot merge. Safety of those operations does not depend
on the network making progress. A delayed candidate callback tagged with an old
epoch cannot alter the current epoch. Receiver candidate knowledge is set union;
a duplicate is not a new session event.

`composed_premises_have_infinite_execution` instantiates the composed theorem
with an explicit infinite cold-start execution, live broker exchanges, both
descriptor streams, and nonempty candidate state. It checks the premises can
hold together. This witness supplements, rather than replaces, the general proof.

### Protocol assumptions

These are premises of the theorem, not conclusions hidden behind the word
“verified.”

| Assumption | Exact role |
| --- | --- |
| Fixed, honest membership; authenticated, well-formed snapshots | Received records originate in the source's actual publication history. A key holder cannot forge another member's messages in this abstraction. |
| Fresh incarnation and credential identifiers | Ghost birth times represent freshness and causality. The wire protocol compares identifiers for equality; it does not order birth times. |
| Unbounded logical counters | Publish increments the clock; receive takes a maximum, including records from the sender's prior incarnation. Arithmetic overflow is outside this protocol specification. |
| Finite external credential resets | Process/agent failures and externally forced retries have a final reset. The arbitrary preceding prefix can contain any finite number of them. Protocol-induced resets from changed answers are **not** assumed to stop; their termination is proved. |
| Fair local processing and recurring publication | A ready sender publishes new full snapshots indefinitely; a receiver repeatedly processes its current input. A responder's readiness is derived from forward delivery, before its reverse-traffic obligation is used. |
| A timely, commonly reachable broker suffix | Infinitely many newly captured publications have a write/read window on a common broker before the publication's lease horizon. Each response is eventually processed. The broker cannot lose its state inside such a protected window; loss and replay outside those windows remain allowed. |
| Full candidate snapshots and epoch-scoped gathering | Every candidate already gathered in that credential epoch occurs in subsequent full snapshots. Switching epochs clears candidate state; stale tagged gathering events are ignored. |

The common-broker assumption permits other brokers to remain down forever. No
quorum or leader is needed. Independent brokers feed one ordered receive state;
they do not each create a separate ICE attempt. The ghost `created` timestamp
uses the selected broker's monotone clock at publication time. It is a proof
device, not a timestamp the client must transmit or a clock-synchronization
requirement.

The lease condition is stronger than eventual reachability: if every copy
expires before a read, fair requests alone cannot guarantee rendezvous. It is
weaker than assuming successful fresh delivery. `BrokerWindow` contains actual
max-register operations and timing premises; `read_window_fresh` derives that
the returned record is at least as recent as the protected publication.

### Why the parts compose

1. `historyFromClock` derives source ordering from the increment/max operations.
   An unbounded publishing suffix eventually exceeds every clock in the finite
   old-incarnation prefix, regardless of boot-ID lexical order.
2. `read_window_fresh` proves lease-protected retention even if a write fails to
   renew the lease because the broker already has a newer record.
3. `common_broker_delivers_every_tail` and
   `transport_preserves_eventual_snapshot_property` derive fresh receive state
   from those broker exchanges and the client's version maximum. Fresh contents
   are not a network assumption.
4. `responder_ordered_suffix` derives monotone offer following from source
   ordering and transport. `answer_unique_between` makes answers unique for
   each offer in that suffix.
5. `initiator_eventually_stable` proves that replay cannot cause infinite
   renegotiation: a new offer born after that suffix cannot have two conflicting
   genuine answers. `renegotiationFromTransitions` derives the reset guard from
   an explicit initiator controller; the guard is not a convergence premise.
6. `responder_follows_stable_offer` and the reverse transport theorem give
   mutual stable credentials. `responder_cold_activation` starts this argument
   without assuming that a responder already has an answer.
7. `candidate_retained_in_stable_epoch` and full-snapshot transport prove
   candidate delivery in the same stabilized credential epoch.

### What this claim excludes

This verifies the specified signaling **state protocol**, under the listed
premises. It does not prove the Go implementation refines the specification,
cryptographic primitives, attestation, HTTP resource limits, Pion, QUIC, STUN,
NAT mapping validity, or successful application connections.

In particular, eventual knowledge is not a latency guarantee. An address can
be delivered correctly after its NAT mapping has expired. Repeated timeout-driven
credential changes also violate the finite-external-reset premise, even when
message delivery is fair. A proof of connection completion before a 90-second
timer would need bounds on publication, polling, processing, mapping lifetime,
and ICE progress. None is asserted by this theorem. See the candidate-lifetime
negative control in [the protocol guide](../README.md).

The Lean state protocol is not proved to refine, or be refined by, the older
`RecoverySpec` TLA+ model. Its bounded TLC prefixes retain their original status;
the unbounded claim here rests on the composed Lean theorem and its explicit
assumptions.

## Admission policy authorization

`authorization_sound` proves that each grant comes from one matching policy
row. The request identity, verified compose hash, and optional peer constraint
must agree in that row; rights from different rows cannot be combined.
`selection_is_first_match` specifies the selected row and the nonmatching
prefix before it. `identity_index_preserves_selection` proves that grouping
rows by identity while retaining order preserves the result.

The proof covers arbitrary list sizes, shared identities and compose hashes,
multiple allowed revisions, wildcard peers, and optional KMS/OS pins.
`profile_matches_spec` gives the exact meaning of enabled and disabled pins.
Pinned KMS mismatch, unverified pinned OS measurements, and pinned OS mismatch
all cause rejection. Disabling a pin imposes no implicit measurement check.

Permissions are typed grant terms. `issued_node_identity_is_confined` and
`issued_agent_read_is_confined` bind self-scoped rights to the request's peer
label and configured datacenter. Service identities, named service writes,
KV-prefix writes, and cluster-wide session writes remain explicit policy
grants. These statements do not prove Consul's interpretation of the terms or
authenticate the physical owner of a quoted peer label.

Kernel-checked witnesses establish that an earlier wildcard can shadow an
exact-peer row with different permissions, that matching fields from different
rows cannot authorize a request, and that a peer-pinned row rejects another
peer even with the same approved revision. The wildcard witness is an
order-dependent policy outcome, not a claim that the current generated policy
contains that overlap.

The specification starts after policy/evidence normalization. It does not
prove parsing, cryptographic verification, nonce freshness, ACL serialization,
or a semantic connection to the Tamarin theory. See the
[security ledger](../security/README.md) for those contracts and the bootstrap
findings that remain open.

## Corrected slot allocation without cleanup

`corrected_allocation_never_duplicates` proves that one instance identifier
never owns two registry slots in the specified ordered CAS protocol. It
quantifies over arbitrary natural-number slot indices, client identifiers,
instance identifiers, execution lengths, and resets. It requires no fairness
or finite-failure assumption because it is a safety property.

The proof derives four invariants from the transition rules:

- Each client's cursor has passed only slots observed to belong to another
  instance.
- A cached nonempty read remains valid because occupied slots cannot change.
- Each captured request carries that same earlier-slot property.
- Every occupied slot has only other owners at earlier indices. This implies
  that its own instance identifier cannot occupy another slot.

These properties are conclusions of `step_preserves` and `trace_invariant`,
not premises supplied to the composed theorem. Capturing a request records it
in ghost history. Any historical request can commit or replay after a reset;
the history is not a physical queue or a storage-boundedness claim. The
`old_request_can_commit_after_reset` witness exercises that delayed-commit path.

The protocol advances a cursor only after reading a foreign owner. A failed
or abandoned CAS may trigger a reread of the same slot; a reset starts at slot
zero. The runtime now uses that reread rule. The previous direct advance after
CAS failure is excluded from this corrected protocol and retained as a TLC
regression control and a deterministic Go regression.

The registry starts empty and supports only atomic create-if-absent writes
from captured protocol requests. There is no deletion, reassignment, malicious
registry writer, or cleanup transition. Consequently, this theorem cannot
justify slot reuse. It also does not prove exclusive live ownership: concurrent
clients can use the same instance identifier and report the same slot.
Allocation progress, finite-pool exhaustion, named-slot provisioning, and
implementation/TLC refinement remain outside this theorem. The
[bootstrap findings](../security/README.md#dynamic-slot-allocation-findings)
record the previous-algorithm and reuse counterexamples.
