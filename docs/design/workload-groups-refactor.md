# Design: Workload Groups Refactor

## Status

Implemented in `clusters/patroni-demo` in this repo. The live Terraform now
defines separate `webdemo` and `postgres` workload groups with separate
compose files, app IDs, compose hashes, slot sets, global
`MESH_ROUTES_JSON`, per-group `LOCAL_BACKENDS_JSON`, and a dedicated
workload egress proxy.

The rest of this document is retained as historical implementation
context. References to the "old", "previous", or "pre-refactor" state
describe the homogeneous worker layout that this work replaced.

## Problem

Before the refactor, the Terraform shape was:

```hcl
worker_replicas = 3

locals {
  mesh_services = [
    { name = "webdemo", port = 8080 },
    { name = "postgres-master", port = 5432, ... },
    { name = "postgres-replica", port = 5432, ... },
  ]
}
```

`phala_app.worker` used one worker compose file, and
`phala_app_instance.worker[...]` created multiple named slots from that
same app. As a result:

- every worker ran `webdemo`;
- every worker ran Patroni/Postgres;
- every new service added to that worker compose file ran on every worker;
- all worker-hosted backends scaled by changing one `worker_replicas`
  value;
- admission policy used one worker app compose hash for every service
  identity hosted by that compose.

The deeper runtime assumption was also homogeneous: the sidecar built
one Envoy per local backend and used that Envoy for both inbound producer
traffic and outbound service-name listeners. That worked only because
every worker that needed to call a service also hosted the service
locally.

For independent workloads, a CVM that runs only `api` must still be able
to call `postgres-master:5432`, even though it does not run Postgres or
own the Postgres producer sidecar.

## Goals

- Let each workload group have its own compose file, image set, slot
  names, replica count, and compose hash.
- Keep one logical mesh cluster: all workload groups join the same
  coordinator set, Consul datacenter, service catalog, and admission
  policy.
- Preserve app-facing service names:
  `http://api:8080`, `postgres-master:5432`, etc.
- Make the Patroni demo an instance of the same model, not a special
  hardcoded path.
- Keep Terraform as the source of truth for workload definitions and
  admission policy.
- Avoid hidden service placement heuristics. Placement should be
  explicit in Terraform.

Non-goals for the first refactor:

- Cross-workload secret derivation without Terraform state exposure.
  The Terraform-state secret workaround remained in scope.
- Automatic rolling updates across workload groups.
- A new user-facing module abstraction. Keep it in the example first;
  extract a module only after the shape proves stable.

## Target Terraform Shape

The desired authoring surface is a map of workload groups:

```hcl
locals {
  workload_groups = {
    api = {
      replicas = 3
      compose  = "${path.module}/compose/api.yaml"
      backends = {
        api = { port = 8080 }
      }
      routes = {
        api = { backend = "api" }
      }
    }

    queue_worker = {
      replicas = 5
      compose  = "${path.module}/compose/queue-worker.yaml"
      backends = {
        queue_worker = { port = 9090 }
      }
      routes = {
        "queue-worker" = { backend = "queue_worker" }
      }
    }

    postgres = {
      replicas = 3
      compose  = "${path.module}/compose/postgres.yaml"
      backends = {
        # One real Postgres server runs in each postgres CVM. Patroni
        # elects its runtime role; Terraform does not assign master or
        # replica at launch time.
        postgres = {
          port         = 5432
          registration = { owner = "workload", parent = var.cluster_name }
          consul_permissions = {
            key_prefixes  = ["service/${var.cluster_name}"]
            session_write = true
          }
        }
      }
      routes = {
        "postgres-master" = {
          backend = "postgres"
          role    = "master"
        }
        "postgres-replica" = {
          backend = "postgres"
          role    = "replica"
        }
      }
    }
  }
}
```

Terminology:

- **workload group**: a replica set with one compose file and one
  scaling knob, such as `postgres` or `api`;
- **backend**: a real local server process exposed by that workload
  group, such as the one Postgres server listening on port 5432 inside
  each `postgres` CVM;
- **route**: a callable mesh name, such as `postgres-master` or
  `postgres-replica`. A route may select a backend by runtime metadata
  such as role.

`backends` and `routes` are both maps because both have stable names that
other config refers to. The map key is the identity. This avoids
duplicating `name = "...";` inside each route and prevents route
reordering from changing derived VIP assignment. Terraform should derive
route VIPs from a sorted route-key list.

`postgres-master` and `postgres-replica` are therefore not two Postgres
processes. They are two route names pointing at one backend type. Patroni
elects which CVM is leader, and the role-watcher publishes the current
role tag to Consul. Consul service-resolver entries use those tags to
route `postgres-master` to the leader and `postgres-replica` to
replicas.

## Mapping To Consul

The proposed config is a higher-level frontend to Consul Connect plus
Phala placement and attestation. It should stay aligned with Consul's
model, but it should not expose raw Consul HCL as the main developer
interface.

| Service mesh config | Consul concept |
|---|---|
| `workload_groups` | No direct Consul equivalent. This is Phala/Terraform placement: one compose file, replica count, app id, slots, and compose hash. |
| `backends.<name>` | A producer-side Consul service registration with `Connect.SidecarService`. |
| `backends.<name>.registration.owner = "platform"` | The mesh sidecar owns the Consul service entry, tags, health check, and sidecar wiring. |
| `backends.<name>.registration.owner = "workload"` | The mesh sidecar creates a Connect-aware stub, then the workload adapter owns dynamic metadata such as role tags and health checks. |
| `backends.<name>.registration.parent` | Parent Consul service used as the source for route selection. Static platform-owned services usually use the backend name. Workload-owned services use it when a runtime adapter publishes tags under a shared parent service. |
| `routes.<name>` | A callable mesh name. This compiles to a local listener plus, when needed, a Consul `service-resolver` redirect. |
| `routes.<name>.role` | A Consul resolver subset selected by a `Service.Tags` filter. |
| `consul_permissions` | ACL policy rules needed by the attested workload token. |

For Patroni, `postgres` is one backend. The routes
`postgres-master` and `postgres-replica` compile to resolver redirects
that select subsets of the `postgres` parent service. Patroni itself
does not get a Terraform-assigned master slot. Patroni elects the
leader at runtime, and the role-watcher updates the parent service tags
that Consul's subsets read.

Each group becomes one `phala_app`:

```hcl
resource "phala_app" "workload" {
  for_each = local.workload_groups

  name    = local.workload_bootstrap_slot[each.key]
  members = local.workload_members[each.key]

  docker_compose = file(each.value.compose)
  env            = local.workload_env_by_slot[each.key][local.workload_bootstrap_slot[each.key]]
}

resource "phala_app_instance" "workload" {
  for_each = local.workload_slots

  app_id = phala_app.workload[each.value.group].app_id
  name   = each.value.slot
  env    = each.value.is_bootstrap ? null : local.workload_env_by_slot[each.value.group][each.value.slot]
}
```

Slot naming should be explicit and stable:

```text
${cluster}-${group}-1
${cluster}-${group}-2
...
```

Mesh peer IDs should also carry the group:

```text
api-0
api-1
postgres-0
postgres-1
postgres-2
```

This replaced the confusing `worker-3` offset caused by placing
coordinators and workers in one ordinal namespace.

## Runtime Model

The sidecar needed to separate two concepts that were fused together:

- **producer backends**: real local servers this CVM hosts and should
  register as Consul Connect endpoints;
- **consumer routes**: service names this CVM may call, regardless of
  whether it hosts the target backend.

Terraform should pass both:

```text
MESH_ROUTES_JSON       # all callable route names in the cluster
LOCAL_BACKENDS_JSON    # producer backends hosted by this workload group
```

All workload CVMs should:

- provision service VIP aliases for every entry in `MESH_ROUTES_JSON`;
- write `/run/mesh/hosts` for every callable route and `/run/mesh/exec.sh`
  for app containers;
- include every producer sidecar port in the mesh-conn allowlist, so
  peer-to-peer forwarding can reach remote producer sidecars;
- run an **egress Envoy** or equivalent local proxy that owns outbound
  listeners for all `MESH_ROUTES_JSON` entries.

Only workload CVMs whose group owns a backend should:

- request backend-specific admission tokens for `LOCAL_BACKENDS_JSON`;
- register producer Consul services and producer sidecars for those
  backends;
- run producer Envoys that listen on `127.50.0.<self-vip>:sidecar_port`;
- run workload-specific registration helpers, such as Patroni's
  role-watcher.

Role assignment is not a Terraform placement decision. For Patroni, every
`postgres` CVM starts the same Postgres/Patroni backend. Patroni uses
Consul as its distributed coordination store, elects a leader at runtime,
and exposes the current role through its REST API. The role-watcher then
updates the single producer service instance with `master` or `replica`
tags. If leadership changes, the tags change; the CVM does not get
redeployed.

### Why An Egress Proxy Is Needed

Without an egress proxy, a CVM that does not host Postgres has no local
process listening on `127.10.0.<postgres-master-vip>:5432`. App code on
that CVM cannot use `postgres-master:5432`.

Consul Connect supports a transparent-proxy style model, but implementing
that would add iptables and DNS capture complexity. The first refactor
should use explicit local listeners because the current system already
uses service VIPs and `/etc/hosts`.

The egress proxy should be generated from `MESH_ROUTES_JSON` and should
not require a local producer registration for every route. The
implementation can be one Envoy bootstrap generated by Consul or by a
small template, but it must be a real routing layer, not a string
rewrite or post-processing workaround.

## Descriptor Shapes

A backend descriptor describes a real local producer:

```json
{
  "owner": "postgres",
  "backend": "postgres",
  "port": 5432,
  "sidecar_port": 21001,
  "parent": "demo",
  "registration_owner": "workload",
  "registers_parent": false,
  "admission_identity": "spiffe://demo/postgres"
}
```

A route descriptor describes a callable name:

```json
{
  "name": "postgres-master",
  "owner": "postgres",
  "backend": "postgres",
  "port": 5432,
  "role": "master",
  "subset": "master",
  "vip": 11
}
```

`owner` is the workload group that hosts the producer backend. It is not
the same as `backend`; `backend` identifies the local server type within
that owner. Multiple routes may point at one backend.

For Patroni:

- `postgres` is the backend;
- `postgres-master` and `postgres-replica` are routes;
- `master` and `replica` are runtime tags published by Patroni, not
  Terraform-assigned CVM roles.

Plan-time checks should enforce:

- compose service image references are literal strings;
- route names are globally unique;
- each `owner/backend` pair has one local port;
- each `owner/backend` pair has one parent service;
- each `owner/backend` pair has one `registration.owner`;
- every workload-owned backend has a non-empty `registration.parent`;
- every route owner exists in `local.workload_groups`;
- each workload group has at least one slot;
- peer IDs are globally unique;
- route VIPs are globally unique;
- producer sidecar ports are globally unique by `owner/backend`.

## Attestation Policy

Admission policy should be generated per workload group.

For each group:

- compute the group-level compose hash from that group's preflight;
- admit the node identity for each slot in that group;
- admit only service identities owned by that group;
- bind policy rows to that group's peer IDs.

Example:

```json
{
  "workload_id": "demo/postgres/0/postgres",
  "identity": "spiffe://demo/postgres",
  "peer_id": "postgres-0",
  "consul_service": "demo",
  "allowed_compose_hashes": ["<postgres-compose-hash>"]
}
```

This fixed the pre-refactor issue where `webdemo` and `postgres` shared
one worker compose hash because they happened to live in the same CVM.

The node identity can remain common:

```text
spiffe://<cluster>/node
```

but its policy rows must be per group and per peer ID, with the
corresponding group compose hash.

## Historical Migration Plan

The migration plan kept the visible Patroni demo behavior while moving
from one homogeneous worker group to separate workload groups:

- three coordinator CVMs;
- separate web backend workload CVMs;
- three Postgres workload CVMs;
- `webdemo` and Postgres no longer colocated in one worker compose file.

The original plan allowed two steps:

### Step 1: Structural Refactor Only

Define one workload group:

```hcl
workload_groups = {
  postgres = {
    replicas = 3
    compose  = "${path.module}/compose/worker.yaml"
    backends = {
      webdemo  = { port = 8080 }
      postgres = { port = 5432, ... }
    }
    routes = {
      webdemo          = { backend = "webdemo" }
      "postgres-master" = { backend = "postgres", role = "master" }
      "postgres-replica" = { backend = "postgres", role = "replica" }
    }
  }
}
```

This removes the hardcoded `worker` resource names and prepares the
resource graph, but it does not yet prove independent service scaling.

### Step 2: Split Webdemo And Postgres

Create separate compose files:

- `clusters/patroni-demo/compose/webdemo.yaml`
- `clusters/patroni-demo/compose/postgres.yaml`

Then define:

```hcl
workload_groups = {
  webdemo = {
    replicas = 3
    compose  = "${path.module}/compose/webdemo.yaml"
    backends = {
      webdemo = { port = 8080 }
    }
    routes = {
      webdemo = { backend = "webdemo" }
    }
  }

  postgres = {
    replicas = 3
    compose  = "${path.module}/compose/postgres.yaml"
    backends = {
      postgres = { port = 5432, ... }
    }
    routes = {
      "postgres-master"  = { backend = "postgres", role = "master" }
      "postgres-replica" = { backend = "postgres", role = "replica" }
    }
  }
}
```

This is the real target because `webdemo` and `postgres` can then scale
independently.

## Original Implementation Plan

1. Rename the Terraform worker concept to workload groups.
   Keep one default group first so the resource graph can be validated
   without changing runtime behavior.

2. Generate global peer topology from all workload group slots:

   ```hcl
   peers = concat(local.coordinator_peers, local.workload_peers)
   ```

3. Generate `MESH_ROUTES_JSON` globally and `LOCAL_BACKENDS_JSON` per
   group.

4. Update admission policy generation to use group-specific preflight
   compose hashes and group-specific peer IDs.

5. Update sidecar runtime to distinguish producer and consumer services.
   Introduce egress listeners for all service names before splitting
   webdemo and Postgres into separate groups.

6. Split compose files and update the demo to use at least two workload
   groups.

7. Update README only after the real deployment passes.

## Original Testing Plan

Local validation:

- `terraform fmt -check clusters/patroni-demo`
- `terraform -chdir=clusters/patroni-demo validate`
- `git diff --check`
- Go tests for all modules
- `STEADY_STATE_OBSERVE_SECONDS=5 go test ./...` in `mesh-conn`

Real cloud validation:

1. Apply one-group structural refactor.
2. Verify:
   - no Terraform drift;
   - `/hello` works;
   - `/all` reaches all webdemo instances;
   - Patroni reports one leader and two streaming replicas.
3. Apply split webdemo/postgres groups.
4. Verify:
   - webdemo CVMs do not run Patroni/Postgres;
   - Postgres CVMs do not run webdemo, unless intentionally retained;
   - webdemo can call `postgres-master` and `postgres-replica`;
   - changing only `webdemo.replicas` does not recreate Postgres slots;
   - changing only `postgres.replicas` does not recreate webdemo slots.

## Risks

### Egress Proxy Complexity

The old producer-side Envoy pattern was not sufficient for consumer
traffic when a workload group does not host a target service. The egress
proxy is the highest-risk part of the refactor.

Mitigation: land the Terraform resource-shape refactor first, then add
the runtime egress/producers split before introducing multiple groups in
the default demo.

### Consul ACL Token Scope

Producer registration tokens and consumer egress tokens may need
different permissions. Current admission mostly issues service identity
tokens to producer workloads.

Mitigation: start with the existing token grants and add a dedicated
egress identity only if Consul rejects the egress proxy config or xDS
watch path.

### Compose Hash Admission

Each group has a different compose hash. A policy bug could accidentally
allow a `webdemo` compose to request a `postgres` token.

Mitigation: generate policy rows from `(group, service owner, peer_id)`
and include tests that assert service identities only reference their
own group preflight hash.

### Slot Naming Drift

Changing peer IDs from `worker-3` to `postgres-0` is cleaner but can
break existing live clusters.

Mitigation: this is acceptable for the new standalone repo before a
stable release. For any migration of an existing production cluster,
keep old peer IDs or document a destructive redeploy.

## Decisions Landed

- Every workload group runs an egress proxy for every route.
- `webdemo` and `postgres` are split immediately.
- Peer IDs are zero-based per group (`webdemo-0`, `postgres-0`).
- The node admission identity remains shared as `spiffe://<cluster>/node`,
  with per-group/per-peer policy rows.
- The egress proxy uses a Consul `connect-proxy` registration and
  Consul-generated Envoy bootstrap.

## Success Criteria

- A developer can define two workload groups with different replica
  counts in Terraform.
- Terraform creates separate `phala_app` resources per workload group.
- Each group has independent stable slots.
- App code can call mesh service names without knowing which group hosts
  the target service.
- Attestation admission only issues a service token to CVMs whose
  compose hash belongs to the owning group.
- The Patroni demo still deploys and reports one leader plus streaming
  replicas.
- Scaling one group produces a Terraform plan that only adds/removes
  that group's slots.
