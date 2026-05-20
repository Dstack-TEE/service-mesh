# Example cluster — peer-VIP / service-VIP layout.
#
# This whole HCL file IS the cluster definition. To bring up an
# HA Postgres + webdemo cluster on dstack:
#
#   PHALA_CLOUD_API_KEY=$(your token) terraform apply -parallelism=1
#
# Migrated to phala-network/phala 0.3.0-beta.1 named-slot (MIG) model:
# coordinators and workers are each ONE `phala_app` with a `members`
# list, and each slot is a `phala_app_instance`. Slot identity
# (`${cluster}-coordinator-0`, `${cluster}-worker-1`, …) is stable
# across CVM replacement; the underlying `vm_uuid` may change but the
# Terraform-declared name does not.
#
# Adding a worker is now a `worker_replicas` bump. The provider creates
# only the new slot (`phala_app_instance.worker["${cluster}-worker-N"]`);
# existing slots keep their `vm_uuid`s. App-level mutations to
# docker_compose / env / image are intentionally blocked at plan time
# in members mode by the provider — see PROGRESS.md for the status of
# slot-preserving rolling updates.

terraform {
  required_version = ">= 1.5"
  required_providers {
    phala = {
      source = "phala-network/phala"
      # 0.3.0-beta.1 introduces phala_app_instance and `members` for
      # MIG-style replica sets. `replicas = N` is removed in 0.3; the
      # new model is one phala_app per role plus one phala_app_instance
      # per slot. Pin exactly because Terraform's `>=` operator
      # doesn't include later prerelease versions; bump this line by
      # hand when a newer beta or the stable 0.3 ships.
      version = "0.3.0-beta.1"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
  }
}

provider "phala" {}

# ---------- Cluster-wide shared secrets (WORKAROUND) ----------
#
# These three secrets MUST be byte-identical across every CVM that
# joins the cluster (gossip auth, Patroni replication, Patroni superuser).
# The principled answer is "derive them in the TEE, never let a human
# touch them" — see attestation-admission.md.
#
# Migration note: in the v0.3 MIG model, all coordinators share ONE
# `app_id` and all workers share another, so within a role
# `dstack.GetKey()` now returns the same bytes on every peer. That
# unlocks in-TEE derivation for role-local secrets in a future change.
# However the secrets here are CROSS-ROLE (coordinators AND workers
# need the same gossip_key, etc.), and the coordinator and worker
# apps have different `app_id`s, so cross-role derivation still
# needs an external source. The terraform-generated random_bytes
# below remain the temporary workaround until attestation-rooted secret
# generation and distribution lands.
#
# Trade-off accepted: anyone with read access to terraform.tfstate
# (or the apply host's memory) sees plaintext keys.
#
# Connect CA root is NOT in this list — Consul's built-in CA provider
# generates the root in Raft on first quorum, no external derivation
# required and no per-CVM problem.
resource "random_bytes" "gossip_key" {
  length = 32
}
resource "random_bytes" "patroni_superuser_pw" {
  length = 32
}
resource "random_bytes" "patroni_replication_pw" {
  length = 32
}
resource "random_bytes" "consul_management_token" {
  length = 32
}

# ---------- Cluster knobs ----------

variable "cluster_name" {
  type    = string
  default = "demo"
}

variable "coordinator_replicas" {
  type        = number
  default     = 3
  description = "Number of voting Consul-server CVMs. 3 gives fault tolerance of 1; 5 of 2."
}

variable "worker_replicas" {
  type    = number
  default = 3
}

variable "gateway_domain" {
  type        = string
  description = "Phala dstack gateway domain (e.g. dstack-pha-prod5.phala.network)"
}

# Image references. The mesh_sidecar image bundles
# bootstrap-secrets, mesh-conn, consul agent, and envoy; workers and
# coordinators both reference it and the entrypoint dispatches on ROLE.
variable "mesh_sidecar_image" { type = string }
variable "webdemo_image" { type = string }
variable "patroni_image" { type = string }
variable "dstack_verifier_image" {
  type        = string
  default     = "dstacktee/dstack-verifier:0.5.9"
  description = "dstack-verifier image used by coordinators for attestation admission. Use a versioned tag; pin by digest in production."
}

variable "kms" {
  type        = string
  default     = "phala"
  description = "Phala Cloud KMS backend used for CVM provisioning. Must match admission_expected_kms_public_key when attestation admission is enabled."

  validation {
    condition     = contains(["phala", "ethereum", "base"], var.kms)
    error_message = "kms must be one of: phala, ethereum, base."
  }
}

variable "production_profile" {
  type        = bool
  default     = false
  description = "Enable stricter production admission checks. Currently requires an explicit os_image and pins the verifier-returned os_image_hash."
}

variable "os_image" {
  type        = string
  default     = ""
  description = "Optional Phala base OS image slug. Required when production_profile is true so the launch config and admission policy share the same explicit OS root."
}

# External coordinator (public-IP coturn + signaling host). Used until
# Phala enables UDP ingress on dstack apps; once that lands we can host
# coturn + signaling inside the dstack mesh and drop these external_*
# vars.
variable "external_coordinator_host" { type = string }
variable "external_signaling_url" { type = string }
variable "external_turn_secret" {
  type      = string
  default   = ""
  sensitive = true
}

# Set to "1" to enable pion's verbose ICE debug logs (connectivity
# checks, STUN attribute parsing). Useful when debugging hot-patch
# / re-handshake flakiness; off by default because it's very chatty.
variable "mesh_conn_debug_ice" {
  type    = string
  default = ""
}

variable "enable_attestation_admission" {
  type        = bool
  default     = true
  description = "Start the coordinator admission broker and require attested workers before issuing Consul node and service tokens."
}

variable "consul_management_token" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Optional Consul management ACL token used by admission-broker to mint scoped tokens. When empty, Terraform generates one."
}

variable "admission_expected_kms_public_key" {
  type        = string
  default     = "3059301306072a8648ce3d020106082a8648ce3d030107034200048844eb42ccdf8c52fd4f174f362fcb9bbd19c45fd48f1edec2d8f1ca23536ec1a74021b4cee610c074f8294d431b2b7fee2c39e5333fdaf0a4522d43fb159d9f"
  description = "Expected dstack key-provider public key hex from verifier app_info.key_provider_info.id. Defaults to the public key for the default phala KMS backend; override when kms is changed."

  validation {
    condition = (
      var.admission_expected_kms_public_key == "" ||
      can(regex("^(0x)?[0-9a-fA-F]+$", var.admission_expected_kms_public_key)) &&
      length(trimprefix(lower(var.admission_expected_kms_public_key), "0x")) % 2 == 0
    )
    error_message = "admission_expected_kms_public_key must be empty or even-length hex, with optional 0x prefix."
  }
}

# ---------- Cluster topology + VIP allocation ----------

locals {
  launch_os_image = trimspace(var.os_image) == "" ? null : trimspace(var.os_image)
  effective_consul_management_token = (
    trimspace(var.consul_management_token) != ""
    ? var.consul_management_token
    : random_bytes.consul_management_token.hex
  )

  # Peer VIPs: 127.50.0.<vip>/32. Allocated as ordinal+1 (so vip=1
  # for the first coordinator, never 0 — the validate_test in
  # mesh-conn rejects vip=0). PEERS_JSON shape: [{id, vip}], same
  # on every CVM. mesh-conn binds the runtime allowlist emitted by
  # mesh-sidecar/entrypoint.sh on every other peer's VIP.
  peers = concat(
    [
      for i in range(var.coordinator_replicas) : {
        id      = "coordinator-${i}"
        ordinal = i
        role    = "coordinator"
        vip     = i + 1
      }
    ],
    [
      for i in range(var.worker_replicas) : {
        id      = "worker-${i + var.coordinator_replicas}"
        ordinal = i + var.coordinator_replicas
        role    = "worker"
        vip     = i + var.coordinator_replicas + 1
      }
    ],
  )

  peers_json = jsonencode([
    for p in local.peers : { id = p.id, vip = p.vip }
  ])

  # COORDINATOR_VIPS — comma-separated for serf retry-join.
  coordinator_vips = join(",", [for p in local.peers : tostring(p.vip) if p.role == "coordinator"])

  # ---------- Service declarations ----------
  #
  # mesh_services is the app-facing service map. For a normal service,
  # declare the name other workloads should call and the local port the
  # container listens on. The lower-level fields consumed by the sidecar
  # are derived below.
  #
  # Optional fields for advanced services:
  #   backend           group multiple public names onto one local server
  #   role              route this name to instances with a matching role tag
  #   workload          admission identity suffix; defaults to backend/name
  #   parent_service    underlying Consul service; defaults to backend/name
  #   registers_parent  false when app code owns service registration
  #   consul_permissions extra Consul ACL rights needed by that workload
  mesh_service_default_permissions = {
    key_prefixes       = []
    session_write      = false
    agent_read_self    = true
    node_identity_self = false
  }

  mesh_services = [
    {
      name = "webdemo"
      port = 8080
    },
    {
      name             = "postgres-master"
      port             = 5432
      backend          = "postgres"
      role             = "master"
      workload         = "postgres"
      parent_service   = var.cluster_name
      registers_parent = false
      consul_permissions = {
        key_prefixes  = ["service/${var.cluster_name}"]
        session_write = true
      }
    },
    {
      name             = "postgres-replica"
      port             = 5432
      backend          = "postgres"
      role             = "replica"
      workload         = "postgres"
      parent_service   = var.cluster_name
      registers_parent = false
      consul_permissions = {
        key_prefixes  = ["service/${var.cluster_name}"]
        session_write = true
      }
    },
  ]

  mesh_services_normalized = [
    for s in local.mesh_services : {
      name             = s.name
      port             = s.port
      role             = try(s.role, null)
      backend          = try(s.backend, s.name)
      workload         = try(s.workload, try(s.backend, s.name))
      parent           = try(s.parent_service, try(s.backend, s.name))
      registers_parent = try(s.registers_parent, try(s.role, null) == null)
      consul_permissions = merge(
        local.mesh_service_default_permissions,
        try(s.consul_permissions, {}),
      )
    }
  ]

  # Backends are producer-side servers. Most services have one public
  # name and one backend. Role-aware services such as Patroni expose
  # several public names, but they still share one local server and one
  # producer-side proxy.
  service_backends = distinct([for s in local.mesh_services_normalized : s.backend])

  backend_sidecar = {
    for idx, b in local.service_backends : b => 21000 + idx
  }

  backend_parent = {
    for b in local.service_backends : b =>
    [for s in local.mesh_services_normalized : s.parent if s.backend == b][0]
  }

  backend_registers_parent = {
    for b in local.service_backends : b =>
    [for s in local.mesh_services_normalized : s.registers_parent if s.backend == b][0]
  }

  # Final per-service descriptors. Keep the JSON shape stable for the
  # existing sidecar/runtime code; only the Terraform authoring surface
  # above changes.
  services = [
    for idx, s in local.mesh_services_normalized : {
      name               = s.name
      port               = s.port
      subset             = s.role
      role               = s.role
      backend            = s.backend
      vip                = 10 + idx
      sidecar_port       = local.backend_sidecar[s.backend]
      parent             = local.backend_parent[s.backend]
      registers_parent   = local.backend_registers_parent[s.backend]
      admission_identity = "spiffe://${var.cluster_name}/${s.workload}"
    }
  ]

  services_json = jsonencode(local.services)

  coordinator_ordinals = {
    for i in range(var.coordinator_replicas) : tostring(i) => i
  }

  worker_ordinals = {
    for i in range(var.worker_replicas) : tostring(i + 1) => i + var.coordinator_replicas
  }

  # In the named-slot provider model, every worker slot belongs to
  # the same phala_app and shares the same measured app-compose.json.
  # A per-slot preflight hashes a different candidate app name, not a
  # different deployed revision, so admission must use the role-level
  # worker evidence from the bootstrap slot.
  worker_admission_preflight_key = "1"
  worker_role_compose_hash       = phala_app_preflight.worker[local.worker_admission_preflight_key].compose_hash
  worker_role_os_image_hash      = phala_app_preflight.worker[local.worker_admission_preflight_key].os_image_hash

  # ---------- Slot identity (v0.3 named-slot model) ----------
  #
  # `members` carries the stable per-CVM names the cloud and Terraform
  # both index by. Slot suffixes match the legacy CVM names so an
  # operator reading `terraform state` doesn't see ordinal drift:
  #
  #   coordinator-0..N-1   ->   ${cluster}-coordinator-0..N-1
  #   worker-1..N          ->   ${cluster}-worker-1..N
  #
  # The PEER_ID in PEERS_JSON is unchanged ("worker-3" for the first
  # worker when there are 3 coordinators) — that's the cluster-wide
  # ordinal the workload sees in env, separate from the slot name.
  coordinator_members = [for i in range(var.coordinator_replicas) : "${var.cluster_name}-coordinator-${i}"]
  worker_members      = [for i in range(var.worker_replicas) : "${var.cluster_name}-worker-${i + 1}"]

  # Per-slot env, keyed by slot name (matches `members` entries).
  # `phala_app.env` (bootstrap CVM) reads from this for `members[0]`;
  # `phala_app_instance.env` reads from it for each non-bootstrap slot.
  coordinator_env_by_slot = {
    for i in range(var.coordinator_replicas) :
    "${var.cluster_name}-coordinator-${i}" => local.coordinator_env[tostring(i)]
  }
  worker_env_by_slot = {
    for i in range(var.worker_replicas) :
    "${var.cluster_name}-worker-${i + 1}" => local.worker_env[tostring(i + 1)]
  }

  # Phase-1 attestation admission policy is keyed by Terraform-defined
  # workload identity. The compose hash is revision evidence, not the
  # workload row key: the same worker compose hosts both example
  # services, so multiple identities intentionally share the worker
  # hash. Each worker also has a node identity used before Consul
  # starts, so the client agent itself joins only after attestation.
  admission_node_identity = "spiffe://${var.cluster_name}/node"

  mesh_workloads = distinct([for s in local.mesh_services_normalized : s.workload])

  admission_service_identities = [
    for workload in local.mesh_workloads : {
      name           = workload
      identity       = "spiffe://${var.cluster_name}/${workload}"
      consul_service = [for s in local.mesh_services_normalized : s.parent if s.workload == workload][0]
      consul_permissions = [
        for s in local.mesh_services_normalized : s.consul_permissions if s.workload == workload
      ][0]
    }
  ]

  worker_preflight_env = {
    for k, ordinal in local.worker_ordinals : k => {
      CLUSTER_NAME            = var.cluster_name
      PEERS_JSON              = local.peers_json
      SERVICES_JSON           = local.services_json
      WORKER_ORDINAL          = tostring(ordinal)
      EXPECTED_REPLICAS       = var.worker_replicas + var.coordinator_replicas
      COORDINATOR_VIPS        = local.coordinator_vips
      SIGNALING_URL           = var.external_signaling_url
      TURN_HOST               = var.external_coordinator_host
      TURN_SHARED_SECRET      = var.external_turn_secret
      MESH_SIDECAR_IMAGE      = var.mesh_sidecar_image
      WEBDEMO_IMAGE           = var.webdemo_image
      PATRONI_IMAGE           = var.patroni_image
      GOSSIP_KEY              = random_bytes.gossip_key.base64
      PATRONI_SUPERUSER_PW    = random_bytes.patroni_superuser_pw.hex
      PATRONI_REPLICATION_PW  = random_bytes.patroni_replication_pw.hex
      MESH_CONN_DEBUG_ICE     = var.mesh_conn_debug_ice
      ADMISSION_BROKER_ENABLE = var.enable_attestation_admission ? "1" : ""
    }
  }

  coordinator_preflight_env = {
    for k, ordinal in local.coordinator_ordinals : k => {
      CLUSTER_NAME            = var.cluster_name
      PEERS_JSON              = local.peers_json
      SERVICES_JSON           = local.services_json
      COORDINATOR_ORDINAL     = tostring(ordinal)
      BOOTSTRAP_EXPECT        = tostring(var.coordinator_replicas)
      COORDINATOR_VIPS        = local.coordinator_vips
      SIGNALING_URL           = var.external_signaling_url
      TURN_HOST               = var.external_coordinator_host
      TURN_SHARED_SECRET      = var.external_turn_secret
      MESH_SIDECAR_IMAGE      = var.mesh_sidecar_image
      DSTACK_VERIFIER_IMAGE   = var.dstack_verifier_image
      GOSSIP_KEY              = random_bytes.gossip_key.base64
      MESH_CONN_DEBUG_ICE     = var.mesh_conn_debug_ice
      ADMISSION_BROKER_ENABLE = var.enable_attestation_admission ? "1" : ""
      # The env key is part of the compose allowlist, but the policy
      # value is not measured. Keep preflight acyclic by hashing with
      # the same key present and an empty value; the deployed resource
      # receives the generated policy JSON below.
      ADMISSION_POLICY_JSON   = ""
      CONSUL_MANAGEMENT_TOKEN = ""
    }
  }

  admission_node_workloads = [
    for k, ordinal in local.worker_ordinals : {
      workload_id    = "${var.cluster_name}/worker/${ordinal}/node"
      identity       = local.admission_node_identity
      peer_id        = "worker-${ordinal}"
      consul_service = ""
      consul_permissions = {
        key_prefixes       = []
        session_write      = false
        agent_read_self    = false
        node_identity_self = true
      }
      allowed_compose_hashes = [local.worker_role_compose_hash]
    }
  ]

  admission_service_workloads = flatten([
    for k, ordinal in local.worker_ordinals : [
      for svc in local.admission_service_identities : {
        workload_id            = "${var.cluster_name}/worker/${ordinal}/${svc.name}"
        identity               = svc.identity
        peer_id                = "worker-${ordinal}"
        consul_service         = svc.consul_service
        consul_permissions     = svc.consul_permissions
        allowed_compose_hashes = [local.worker_role_compose_hash]
      }
    ]
  ])

  admission_workloads = concat(local.admission_node_workloads, local.admission_service_workloads)

  admission_policy_json = jsonencode({
    cluster      = var.cluster_name
    policy_epoch = 1
    kms = var.admission_expected_kms_public_key == "" ? null : {
      name = "kms"
      id   = var.admission_expected_kms_public_key
    }
    os_image = var.production_profile ? {
      image = local.launch_os_image
      hash  = local.worker_role_os_image_hash
    } : null
    workloads = local.admission_workloads
  })

  coordinator_env = {
    for k, env in local.coordinator_preflight_env : k => merge(env, {
      ADMISSION_POLICY_JSON   = local.admission_policy_json
      CONSUL_MANAGEMENT_TOKEN = local.effective_consul_management_token
    })
  }

  worker_env = local.worker_preflight_env
}

# ---------- Worker preflight (role revision evidence) ----------
#
# Kept as a `for_each` to exercise the same env-key shape used by every
# worker slot. The admission policy intentionally uses the bootstrap
# worker preflight only: in members mode all worker slots share one
# phala_app and therefore one measured app-compose.json.

resource "phala_app_preflight" "worker" {
  for_each = local.worker_ordinals

  name           = "${var.cluster_name}-worker-${each.key}"
  size           = "tdx.small"
  region         = "US-WEST-1"
  image          = local.launch_os_image
  disk_size      = 20
  storage_fs     = "zfs"
  docker_compose = file("${path.module}/../compose/worker.yaml")
  env_keys       = sort(keys(local.worker_preflight_env[each.key]))

  listed         = false
  public_logs    = true
  public_sysinfo = false
}

# ---------- Coordinator app + slots ----------
#
# Single `phala_app.coordinator` owns the coordinator replica set's
# app identity and the bootstrap CVM (the slot named
# `local.coordinator_members[0]`). The other coordinator slots are
# declared as `phala_app_instance.coordinator` entries; each carries
# its own per-slot env so bootstrap-secrets sees the right
# COORDINATOR_ORDINAL on every peer.

resource "phala_app" "coordinator" {
  name    = local.coordinator_members[0]
  members = local.coordinator_members

  size           = "tdx.small"
  region         = "US-WEST-1"
  image          = local.launch_os_image
  kms            = var.kms
  disk_size      = 20
  storage_fs     = "zfs" # MUST pin (terraform-provider-phala#5)
  docker_compose = file("${path.module}/../compose/coordinator.yaml")

  env = local.coordinator_env_by_slot[local.coordinator_members[0]]

  listed         = false
  public_logs    = true
  public_sysinfo = false

  wait_for_ready       = true
  wait_timeout_seconds = 600

  lifecycle {
    precondition {
      condition     = !var.enable_attestation_admission || var.admission_expected_kms_public_key != ""
      error_message = "admission_expected_kms_public_key must be set when enable_attestation_admission is true."
    }
    precondition {
      condition     = !var.production_profile || local.launch_os_image != null
      error_message = "os_image must be set when production_profile is true."
    }
  }
}

resource "phala_app_instance" "coordinator" {
  for_each = toset(phala_app.coordinator.members)

  app_id = phala_app.coordinator.app_id
  name   = each.value

  # Bootstrap slot is adopted from phala_app.coordinator; its env
  # lives on phala_app.coordinator.env. Provider rejects env on the
  # adopted slot, so we pass null there.
  env = each.value == phala_app.coordinator.name ? null : local.coordinator_env_by_slot[each.value]

  wait_for_ready       = true
  wait_timeout_seconds = 600
}

# ---------- Worker app + slots ----------
#
# Workers depend on the full coordinator quorum: each worker's Consul
# client retry-joins the coordinator serf addrs immediately on boot,
# so applying workers before all 3 coordinator slots are up just
# generates noise. The explicit `depends_on` on the COLLECTIVE
# `phala_app_instance.coordinator` (not just `phala_app.coordinator`)
# is what gates workers behind every coordinator slot, not just the
# bootstrap one.

resource "phala_app" "worker" {
  name    = local.worker_members[0]
  members = local.worker_members

  size           = "tdx.small"
  region         = "US-WEST-1"
  image          = local.launch_os_image
  kms            = var.kms
  disk_size      = 20
  storage_fs     = "zfs"
  docker_compose = file("${path.module}/../compose/worker.yaml")

  env = local.worker_env_by_slot[local.worker_members[0]]

  listed         = false
  public_logs    = true
  public_sysinfo = false

  wait_for_ready       = true
  wait_timeout_seconds = 600

  # Plan-time checks for the app-facing mesh_services declarations.
  # The runtime sidecar expects one port, parent service, and
  # registration mode per backend, so Terraform catches inconsistent
  # authoring before any CVM is created.
  lifecycle {
    precondition {
      condition     = length(local.services) == length(distinct([for s in local.services : s.name]))
      error_message = "local.mesh_services has duplicate service names. Each callable service name must be unique."
    }
    precondition {
      condition = alltrue([
        for b in local.service_backends :
        length(distinct([for s in local.mesh_services_normalized : tostring(s.port) if s.backend == b])) == 1
      ])
      error_message = "Each mesh backend must use exactly one local port. Split services into different backends when they listen on different ports."
    }
    precondition {
      condition = alltrue([
        for b in local.service_backends :
        length(distinct([for s in local.mesh_services_normalized : s.parent if s.backend == b])) == 1
      ])
      error_message = "Each mesh backend must map to exactly one parent_service."
    }
    precondition {
      condition = alltrue([
        for b in local.service_backends :
        length(distinct([for s in local.mesh_services_normalized : tostring(s.registers_parent) if s.backend == b])) == 1
      ])
      error_message = "Each mesh backend must use one registers_parent mode."
    }
    precondition {
      condition = alltrue([
        for w in local.mesh_workloads :
        length(distinct([for s in local.mesh_services_normalized : s.parent if s.workload == w])) == 1
      ])
      error_message = "Each mesh workload must map to exactly one parent_service because admission issues one Consul token per workload identity."
    }
    precondition {
      condition = alltrue([
        for w in local.mesh_workloads :
        length(distinct([for s in local.mesh_services_normalized : jsonencode(s.consul_permissions) if s.workload == w])) == 1
      ])
      error_message = "Each mesh workload must use one consul_permissions shape because admission issues one Consul token per workload identity."
    }
  }

  depends_on = [phala_app_instance.coordinator]
}

resource "phala_app_instance" "worker" {
  for_each = toset(phala_app.worker.members)

  app_id = phala_app.worker.app_id
  name   = each.value

  env = each.value == phala_app.worker.name ? null : local.worker_env_by_slot[each.value]

  wait_for_ready       = true
  wait_timeout_seconds = 600
}

# ---------- Outputs ----------
#
# `coordinator_app_id` and `worker_app_id` are now singular strings
# (one app_id per role) — previously they were maps keyed by ordinal
# because each ordinal was its own app. Consumers that previously
# indexed `coordinator_app_ids["0"]` should read `coordinator_app_id`
# instead. Per-slot vm_uuids are exposed via the *_slot_uuids maps.

output "coordinator_app_id" { value = phala_app.coordinator.app_id }
output "worker_app_id" { value = phala_app.worker.app_id }

output "coordinator_slot_uuids" {
  description = "Map of stable coordinator slot name -> current vm_uuid. The slot name is durable; vm_uuid may change on CVM replacement."
  value       = { for k, s in phala_app_instance.coordinator : k => s.vm_uuid }
}

output "worker_slot_uuids" {
  description = "Map of stable worker slot name -> current vm_uuid."
  value       = { for k, s in phala_app_instance.worker : k => s.vm_uuid }
}

output "admission_policy_json" { value = local.admission_policy_json }

output "worker_preflight_compose_hashes" {
  value = { for k, w in phala_app_preflight.worker : k => w.compose_hash }
}

output "consul_ui" {
  # Coordinator-0's Consul HTTP API on the canonical 8500. Plain HTTP
  # backend → use the no-`s` gateway form (gateway terminates TLS).
  # See README "dstack gateway URL convention".
  value = "https://${trimprefix(phala_app.coordinator.app_id, "app_")}-8500.${var.gateway_domain}/ui"
}

output "webdemo_url" {
  description = "Public gateway URL for the worker webdemo service. Use /hello for one worker and /all to fan out through the mesh."
  value       = "https://${trimprefix(phala_app.worker.app_id, "app_")}-8080.${var.gateway_domain}"
}
