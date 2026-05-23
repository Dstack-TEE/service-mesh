# Design docs — open work, intentionally separate from the user-facing docs

This directory holds design briefs and handoff notes for open or
partially landed work on `service-mesh`. Each doc is structured
so an agent (or a person) can pick it up cold and continue.

The user-facing docs (`README.md`, `ARCHITECTURE.md`, `FAILOVER.md`,
`PUBLISHING.md`, `ROBUSTNESS.md`) describe what's *shipping today*.
This directory describes what's *next*. They're intentionally
separated so a user landing on the example doesn't get a roadmap
in their face.

| Doc | What |
|---|---|
| [`attestation-admission.md`](attestation-admission.md) | Phase 1 admission is implemented. Remaining work: token lifecycle, non-NAT secret distribution, upgrade policy, and rendezvous hardening. |
| [`terraform-slot-api.md`](terraform-slot-api.md) | Provider slot resources are implemented and validated. Remaining work: slot-preserving revision rollout through the Cloud redeploy endpoint. |
| [`workload-groups-refactor.md`](workload-groups-refactor.md) | Historical design notes for the workload-group split now implemented in `cluster-example`. |

Each doc includes:

- The current state and why it falls short
- What "done" looks like
- A concrete approach with a code/structure sketch
- Risks + mitigations
- Open questions for the implementing agent
- Success criteria
- Hand-off instructions

When all open work in a doc lands, delete the doc; the implementation
and user-facing docs are the surviving artifacts.
