# Protocol models

This directory specifies the mesh protocols and checks their properties. It
contains [unbounded Lean protocol proofs](proof/README.md),
[symbolic security models](security/README.md), finite TLA+ models,
counterexample controls, and reproducible verification runners.

The composed Lean theorem proves conditional convergence of the leaderless
signaling state protocol: offers and answers stabilize, both peers learn the
same credentials, and candidates gathered in that stable epoch are eventually
delivered. Separate safety lemmas cover provenance, ordering, offer binding,
and candidate isolation. This is a protocol proof, not a Go implementation proof.

## Verification scope

The completed signaling proof targets the leaderless algorithm: snapshot ordering,
offer/answer binding, candidate state, and recovery across peer and broker
failures. Go implementation refinement, attestation admission, and proofs of
cryptographic primitives remain outside that theorem. Admission authorization
and shared-key signaling authentication now have separate symbolic security
models. Their [claim ledger and roadmap](security/README.md) record the
assumptions, counterexamples, and remaining composition work.
Admission policy selection also has an unbounded Lean proof. A separate
bootstrap model checks the corrected dynamic allocator within explicit finite
bounds and retains the old CAS-failure behavior as a regression control. A separate Lean
theorem proves one-slot-per-instance for the corrected no-cleanup protocol
over unbounded executions.

The signaling specification assumes fixed honest membership, authenticated
messages, fresh identifiers, and unbounded logical counters. Its liveness result
requires finite external process/agent resets, fair local execution and periodic
full snapshots, and a commonly reachable broker with recurring write/read
exchanges inside a lease window. Protocol-induced renegotiation is proved to
stop; its termination is not an assumption. Other brokers can remain down.

Read the [proof's assumption ledger](proof/README.md#protocol-assumptions) before
using the claim. The theorem proves eventual signaling knowledge, without a
latency bound, NAT-usability guarantee, or ICE/QUIC connection theorem. Repeated
timeout-driven credential regeneration is outside the finite-external-reset
premise; fair message delivery alone does not rule it out.

The older composed TLA+ model still has eight-transition safety-prefix checks.
Those finite checks and the Lean proof are different specifications; no
refinement theorem between them or the Go implementation is claimed.

## Run the checks

Run the suites from the repository root. The [Lean runner](proof/README.md)
requires Python 3.11+, `curl`, GNU `tar`, and `zstd` on Linux x86-64:

```sh
python3 protocol/proof/check.py
```

For finite TLC checks, prerequisites are Python 3.10+, Java (tested with OpenJDK
17), and `curl` for the first download:

```sh
python3 protocol/check.py
```

For unbounded symbolic security checks on Linux x86-64, with Python 3.12+
and `curl`:

```sh
python3 protocol/security/check.py
```

The security runner pins Tamarin and Maude and checks both proved properties
and expected attack traces. Its results do not establish project-wide security
or compose with the signaling theorem automatically.

The TLC runner downloads [TLA+ tools 1.7.4](https://github.com/tlaplus/tlaplus/releases/tag/v1.7.4)
to `$XDG_CACHE_HOME/dstack-service-mesh/tla2tools/1.7.4/` (default
`~/.cache/`). It verifies a pinned SHA-256 checksum before executing the JAR.
An existing `TLA2TOOLS_JAR` path can supply the same pinned artifact offline.

Run a single family or refresh the checked-in evidence:

```sh
python3 protocol/check.py --only handshake
python3 protocol/check.py --report protocol/verification.json
```

Full TLC output and a JSON report are saved under `.local/protocol-checks/`.
Use `--logs PATH` to choose another destination. Every check has a 120-second
timeout; exhaustion, a timeout, or a parser/runtime error fails the runner.
Checks use exhaustive breadth-first search, one worker, and a fixed fingerprint
polynomial. They do not use random simulation, state constraints, or symmetry
reduction. `CHECK_DEADLOCK FALSE` allows idle/waiting states; connection progress
is checked separately as a temporal property.

The suite distinguishes six outcomes:

| Label | Required result |
| --- | --- |
| `VERIFIED MODEL` | TLC completes the reachable state graph without an invariant or temporal-property violation. |
| `BOUNDED SAFETY PREFIXES` | TLC completes the explicitly limited prefix graph; no composed liveness claim is made. |
| `COUNTEREXAMPLE CONTROL` | A deliberately weakened model violates the specified property. |
| `LIFECYCLE/ASSUMPTION COUNTEREXAMPLE` | A changed lifecycle or trust assumption produces the named violation. |
| `REACHABILITY WITNESS` | An intentionally false invariant produces a trace reaching successful acceptance, connection, or token issuance. |
| `FAIL` | Any result differs from its expected outcome. |

An arbitrary nonzero exit is never accepted as a counterexample. The runner
checks the TLC exit code and the specific invariant's diagnostic. The temporal
control has only one temporal property, `EventuallyConnected`.

## Verification inventory

| Order | Protocol or state machine | Current status | Scope |
| --- | --- | --- | --- |
| 0 | [Composed signaling state protocol](proof/Signaling.lean) | Unbounded conditional convergence and safety lemmas kernel-checked | Arbitrary natural-number traces and finite pair counts; explicit authentication, finite external resets, fairness, publication, and lease-window premises. |
| 0a | [Admission policy authorization](proof/AdmissionPolicy.lean) | Unbounded authorization, first-match selection, and self-scope confinement kernel-checked | Arbitrary normalized policy lists, optional KMS/OS pins, wildcard peers, and shared identities/revisions; typed permission terms. |
| 0b | [Corrected no-cleanup slot allocation](proof/SlotAllocation.lean) | Unbounded one-slot-per-instance safety kernel-checked | Arbitrary ordered-scan traces with resets and replayable captured CAS requests; empty initial registry and no deletion, replacement, or unauthorized writes. No exclusive-live-ownership or progress claim. |
| 1 | [Snapshot storage and receive ordering](snapshots/SnapshotStore.tla) | Safety checks pass | One authenticated directed stream, three independent brokers, clocks 1–2, two distinct boot IDs in either lexical order. |
| 2 | [ICE offer/answer coordination](handshake/OfferAnswer.tla) | Safety and conditional liveness pass | One peer pair, two and three offers, two and three responder generations per offer. |
| 3 | [Attempt callback ownership](attempts/AttemptOwnership.tla) | Safety checks pass | Two sequential attempts, callbacks delayed across cleanup and replacement. |
| 4 | [Candidate callback isolation and replay](candidates/CandidateReplay.tla) | Safety and conditional replay progress pass | Two local auth generations, two agents, two candidates, stable remote credentials. |
| 5 | [Attested admission sequencing](admission/Admission.tla) | Safety checks pass | One broker-local nonce, two competing requests, all 1,024 combinations of five check results. |
| 6 | [Combined restart and broker-loss recovery](recovery/RendezvousRecovery.tla) | Bounded safety prefixes pass; integrated liveness unverified | Two peers, two brokers, one restart per peer, eight transitions from cold and established states, clocks through four, two auth generations per boot, two-tick leases. |
| 6a | [Candidate mapping lifetime](lifetime/CandidateLifetime.tla) | Environmental controls reproduce expiry despite intact delivery | Explicit finite peer delay, mapping lifetime, and delivery delay; outside the signaling-state theorem. |
| 7 | [Symbolic authentication and admission](security/README.md) | Unbounded symbolic safety and expected attack witnesses pass | Ideal cryptographic primitives, protected channels, shared platform authority across brokers, and one pinned policy row per broker; separate from the Lean theorems. |
| 8 | Mesh stream framing and port authorization | Unmodeled | These belong to the mesh data plane. |
| 9 | [Dynamic slot ownership](bootstrap/SlotOwnership.tla) | Corrected scan passes; old CAS-failure behavior retained as a regression control | Two processes, two slots, one reboot each; delayed requests and lost replies. Administrative reuse and duplicate-instance boundaries also fail stronger goals. No liveness or named-slot claim. |
| 10 | [Cloud API read retries](deployment/README.md) | Retry limits, timing, cancellation, termination, and conditional recovery checked in finite scenarios | Explicit HTTP and operation deadlines, bounded throttling, and urgent local processing; separate from signaling and whole-deployment progress. |

[proof/verification.json](proof/verification.json) records the Lean tool pin,
per-proof source hashes and axiom audits. [verification.json](verification.json) records the
latest TLC run, state counts, model/config hashes, tool checksum, and reviewed implementation hashes.
The GitHub workflow reruns the Lean, TLC, and symbolic security suites, tests
the bootstrap allocator with Go's race detector, and uploads fresh proof logs. Source hashes
identify what was reviewed; they do not establish implementation refinement.

## What each model checks

### Snapshot storage

The model follows `signalRecord.newer`, `signalBroker.ServeHTTP`,
`signalClient.snapshot`, and `signalClient.accept` in
[signaling.go](../components/mesh-conn/signaling.go).

`Write` models a delayed authenticated request. `Read` creates a response that
can be delivered repeatedly, even after the broker forgets its records.
`Forget` represents expiry or broker restart. Reads leave stored records intact.
Sender and receiver restarts reset their volatile clocks and receive state;
random boot IDs are unique but may increase or decrease lexically.

The invariants check:

- Each broker retains the greatest version written since its last `Forget`.
- Each receiver retains the greatest version delivered since its last restart.
- Its Lamport clock covers its accepted record.
- A publication's clock exceeds every authenticated clock its sender observed
  before that publication, including records from its previous incarnation.
- Stored and accepted records originate in the modeled published history.
- Storage has one cell per broker for this directed stream.

`storeMax` and `acceptedMax` are independent history observers. Disabling the
ordering guards makes the model disagree with those observers. This gives
separate broker and client regression counterexamples.
Ignoring the receive rule for the sender's own records produces a publication
freshness violation after restart. This verifies the local recovery rule, not
end-to-end convergence through a broker.

This is an ordering model. It abstracts authenticated records to `(clock, boot)`
and does not model candidate payloads, HMAC, HTTP parsing, byte limits, or timing.
Clock values are finite exploration bounds. Publishing stops at the bound; no
liveness claim depends on that boundary. The model does not prove fresh-session
convergence after losing every volatile clock or cache.

### Offer/answer coordination

The model follows the deterministic initiator selection, responder offer echo,
and `applySignalRecord` handling in [main.go](../components/mesh-conn/main.go).
Offers and responder generations are symbolic fresh IDs. `Rank` preserves the
order of authentication changes within this model. Repeated snapshots of the
same credentials are modeled as duplicate deliveries without changing that rank.

The invariants check that a stored answer names the current offer, a connected
pair agrees on its offer and live responder credentials, and duplicates cannot
tear down a healthy link. Old published answers remain available for delayed
delivery. Local retries can happen before or after connection, within the bounds
in each configuration.

`EventuallyConnected == <>[]up` means that a connection eventually stays up.
The specification assumes weak fairness for current-offer delivery, answer
generation, current-answer delivery, and successful connection establishment.
In concrete terms: after the finite failures, both peers must keep making
progress, a common broker must deliver current snapshots, and a viable direct
path must allow ICE/QUIC to complete. Removing fairness produces the expected
stalled execution.

Candidate gathering, the Go channel/lock interleavings, and ICE/QUIC internals
are abstracted. No broker topology is modeled here. Thus this conditional
liveness result does not establish that the snapshot protocol satisfies its
delivery assumptions. The separate composed Lean theorem proves conditional
signaling convergence; no refinement theorem connects it to this finite model.

### Attempt callback ownership

Every asynchronous cancellation callback must affect only the attempt that
created it. The current implementation routes the timer, ICE-state, and candidate
error callbacks through `peerSession.abortAgent(agent)`. That method checks agent
identity under the session mutex before invoking the current cancellation
function. Its abstract invariants pass.

The negative control [UnguardedTimer.cfg](attempts/UnguardedTimer.cfg) removes
that identity guard. TLC then finds this execution:

1. Attempt 1's timer callback starts and waits for the session lock.
2. Attempt 1 finishes. `Stop()` cannot stop the already-started callback.
3. Attempt 2 installs its own cancellation function in the session.
4. Attempt 1's callback resumes and cancels attempt 2.

That execution is permitted by the documented
[Go `Timer.Stop` contract](https://pkg.go.dev/time#Timer.Stop), which does not
wait for an already-started callback. The current ownership guard rejects the
stale callback. `TestRetiredAgentCallbacksCannotCancelReplacement` in
[signaling_test.go](../components/mesh-conn/signaling_test.go) tests this
replacement interleaving against the actual helper. The unguarded ICE callback
is another negative control.

### Candidate callback isolation and replay

The model follows `signalClient.addCandidate` in
[signaling.go](../components/mesh-conn/signaling.go) and the captured-agent
delivery and buffer replay in `applySignalRecord` and `dialICE` in
[main.go](../components/mesh-conn/main.go).

Two local authentication generations allow callbacks from a retired agent to
arrive after new credentials are installed. Only callbacks with current local
credentials may add to the published candidate set. For remote candidates,
`Receive` updates the buffer and captures its destination agent. `Deliver` may
run later, after the replacement is installed. `Replay` copies the buffer to the
replacement. Duplicate candidates leave buffer and delivery state unchanged.

The invariants require local publication to match its originating credentials,
pending deliveries to keep their captured destination, and the replacement to
contain every buffered candidate once replay and pending deliveries finish.
With fair replay/delivery actions, the replacement eventually catches up.
Removing the local auth check, looking up the current agent at delivery time,
or omitting replay each produces its own counterexample.

This cut holds remote credentials fixed and assumes candidate additions to the
live replacement succeed. It covers the retained-buffer responder replacement
case. It does not prove the composition with changing remote credentials,
initiator offer replacement, Pion's internal state machine, or agent closure.

### Attested admission sequencing

The model follows `handleAttest` and `NonceStore.Consume` in the
[admission broker](../components/admission-broker/main.go). It separates atomic
nonce consumption, external verification, and token issuance so concurrent
requests can interleave between those steps.

The policy in this model pins both KMS and OS image. Five predicates represent
valid evidence, correct report-data binding, the KMS match, the verified OS-image
match, and the workload policy match. Every predicate combination is explored
for both requests. External failures and nonce expiry may occur between steps.
An already-consumed request may finish after expiry, matching the Go behavior.

The invariants require at most one nonce consumption and one grant, every
mandatory predicate for any grant, and consumption before granting. Controls
omit each predicate individually or disable consumption, producing explicit
unauthorized-grant and replay traces.

The actual policy can leave KMS or OS image unpinned. Such configurations do not
inherit this model's mandatory-pinning claim. One nonce is generated once and
never reused. Randomness, nonce collisions, verifier cryptography, ACL rule
construction, token leakage, policy changes, and multi-broker failover are outside
this model. Admission liveness is not claimed.

### Composed recovery: initial safety exploration

[RendezvousRecovery](recovery/RendezvousRecovery.tla) combines independent broker
stores and leases, peer incarnation changes, Lamport receive rules, buffered
remote auth/candidates, offer changes, and connection establishment. HTTP requests
and responses occupy incarnation-indexed slots. A request created by a dead
process can still reach the server. A response to that dead process does not
update its replacement's state. Separate witnesses require both cases to be
reachable. Lost requests and responses are allowed before stabilization.

The initial safety runs explore every abstract execution prefix of at most eight
transitions from a cold-start state and a seeded established-link state. There
are two peers, two brokers, one restart per peer, clocks through four, at most
two auth generations per boot, and a two-tick lease. Within those bounds the
checks cover answer binding, publication freshness, types, and consistency of
the stable-broker environment. Disabling offer binding yields a stale answer
accepted after initiator restart. That control is an altered algorithm, not a
current implementation failure.

These are short prefixes. In particular, eight transitions do not cover a full
cold-start handshake and subsequent restart/rejoin. A counterexample cannot be
excluded beyond these bounds. The established-link initial state is a specified
protocol state; the model has not proved its refinement from the concrete Go
bootstrap execution. Counter and generation limits stop further actions at the
frontier; they never clamp counters or justify a liveness conclusion.

`Stabilize` is an environment action which ends peer restarts, broker faults,
and call losses and makes one common broker reachable. Its weak fairness is the
explicit finite-failure assumption in the unbounded `RecoverySpec`. After that,
both peers must complete a common-broker exchange within each lease tick before
the modeled clock advances. This is the timely-delivery assumption needed for
leases, not an assumption that a handshake succeeds. Current-offer generation,
publication, serving, response delivery, gathering, consumption, and a viable
direct-path connection each have progress assumptions. Unbounded clocks are
available with `Bounded = FALSE`; **the unbounded `RecoverySpec` progress obligation has not
been model-checked or proved**. The composed Lean theorem is the separate
unbounded signaling-state result; no refinement to this TLA+ specification is
asserted.

Important omissions remain: Go channel/lock interleavings inside the response
macrostep, same-process HTTP timeouts with late server execution, timeout-driven
ICE retries, arbitrary boot-ID lexical orders in this composed model, Pion
internals, and multiple direct candidates. SnapshotStore checks both boot-ID
orders separately. CandidateReplay checks the captured-agent/replay cut
separately. Neither TLC family establishes composition with this TLA+ recovery model.
The independent Lean proof composes its own state-machine definitions.

## Candidate lifetime controls

[CandidateLifetime](lifetime/CandidateLifetime.tla) isolates a network condition
that successful signaling cannot resolve. Credentials and candidates are
correctly delivered; the first connectivity check happens at the earliest
modeled time. The mapping can still expire before that check.

- `EagerExpired`: a three-tick mapping gathered before a six-tick peer startup
  delay is stale by delivery. `AttemptWorks` must fail.
- `DeferredExpired`: gathering waits for the peer, but a two-tick mapping expires
  during two ticks of signaling. `AttemptWorks` must still fail.
- `DeferredFresh`: with three ticks of lifetime and two ticks of signaling, the
  simplified check succeeds. `Reachable` independently witnesses that success.

These constants illustrate the timing relationship; they are not production
measurements. The model does not implement STUN, ICE checks, keepalives, NAT
refresh, or network scheduling. It makes the proof boundary executable: a
correctly delivered descriptor does not prove its address is currently usable.

## Threat and proof boundaries

The snapshot and handshake models assume authenticated, correctly formed
messages from uncompromised participants. They allow delivery faults, not
forgeries. The shared bootstrap secret lets a holder derive any peer's signing
key. Therefore the current design does not provide peer impersonation resistance
against a compromised holder of that secret. That must be explicit in the later
cryptographic model.

The models assume fresh ICE credentials and boot IDs. They do not prove entropy,
cryptographic primitives, TEE/verifier correctness, STUN behavior, NAT traversal,
Consul, Envoy, or QUIC. QUIC currently does not verify certificates; the binding
between admission, signaling credentials, and transport peers remains a separate
security verification task.

TLC explores every reachable state of each supplied finite configuration.
Passing those checks is bounded model-checking evidence. The unbounded theorem
is checked separately by Lean. Neither suite proves every Go execution refines
the specifications or proves the two formalizations equivalent.

## Extend the verification one protocol at a time

1. Map the exact code transitions, persistent state, volatile state, and fault
   assumptions before changing a model. Keep omitted behavior explicit.
2. State safety invariants separately from progress properties. State the
   scheduling and network assumptions required for progress.
3. Add a finite configuration, a successful-execution witness, and a weakened
   configuration that must violate the intended property. Require the exact
   diagnostic, not just a failed command.
4. Run `python3 protocol/check.py --only FAMILY`. Investigate every unexpected
   trace before modifying either the model or the implementation.
5. For an implementation finding, add a deterministic Go regression, make the
   algorithmic fix, and update the correspondence and status together. Do not
   suppress a trace by adding a timing assumption solely to make it pass.
6. Rerun both suites and refresh their evidence reports. Record the precise
   premises and conclusions. For Lean changes, require a complete proof and
   axiom audit; passing finite TLC prefixes cannot replace that obligation.
