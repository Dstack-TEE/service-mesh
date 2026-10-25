# Example cluster — peer-VIP / service-VIP layout.
#
# This whole HCL file IS the cluster definition. To bring up an
# HA Postgres + webdemo cluster on dstack:
#
#   PHALA_CLOUD_API_KEY=$(your token) terraform apply -parallelism=1
#
# Uses the phala-network/phala 0.3 named-slot (MIG) model:
# coordinators and each workload group are each ONE `phala_app` with a
# `members` list, and each slot is a `phala_app_instance`. Slot identity
# (`${cluster}-coordinator-0`, `${cluster}-webdemo-1`, …) is stable
# across CVM replacement; the underlying `vm_uuid` may change but the
# Terraform-declared name does not.
#
# Adding workload capacity is now a group replica bump. The provider
# creates only the new slot; existing slots keep their `vm_uuid`s.

terraform {
  required_version = ">= 1.5"
  required_providers {
    phala = {
      source = "phala-network/phala"
      # 0.3.0-beta.3 exposes gateway_base_domain so public URLs can be
      # derived from provider state instead of a hardcoded gateway suffix.
      # 0.3.0-beta.4 is the official-Go-SDK migration build.
      version = "0.3.0-beta.4"
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
# The gossip key MUST be byte-identical across every CVM that joins the
# cluster (gossip auth). The principled answer is "derive it in the TEE,
# never let a human touch it" — see ../../docs/design/attestation-admission.md.
#
# Migration note: in the v0.3 MIG model, all coordinators share ONE
# `app_id` and each workload group app has its own `app_id`, so within
# a role `dstack.GetKey()` now returns the same bytes on every peer. That
# is enough for ROLE-LOCAL secrets (see the TEE-rooted list below). The
# gossip key is CROSS-ROLE, though — coordinators AND workload apps need
# the same value, and they have different `app_id`s, so GetKey cannot
# produce it for all of them. The terraform-generated random_bytes below
# remains the temporary workaround until attestation-rooted cross-role
# secret generation and distribution lands.
#
# Trade-off accepted: anyone with read access to terraform.tfstate
# (or the apply host's memory) sees this plaintext key.
#
# NOT in this list (rooted in the TEE instead):
#   - Consul ACL management token — role-local to the coordinators (one
#     app_id), derived in-TEE by bootstrap-secrets.
#   - Patroni superuser + replication passwords — role-local to the
#     postgres app (one app_id across replicas), derived in-TEE by
#     bootstrap-secrets when DERIVE_PATRONI_PASSWORDS=1. Never in tfstate.
#   - Connect CA root — Consul's built-in CA generates it in Raft on first
#     quorum; no external derivation and no per-CVM problem.
resource "random_bytes" "gossip_key" {
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

variable "webdemo_replicas" {
  type        = number
  default     = 2
  description = "Number of webdemo workload CVMs."

  validation {
    condition     = var.webdemo_replicas > 0
    error_message = "webdemo_replicas must be positive."
  }
}

variable "postgres_replicas" {
  type        = number
  default     = 3
  description = "Number of Patroni/Postgres workload CVMs. Use 3 or more for HA."

  validation {
    condition     = var.postgres_replicas > 0
    error_message = "postgres_replicas must be positive."
  }
}

# Image references live in the compose files. Edit compose to change
# image identity. Pin images by digest when compose hashes are used for
# production admission policy.

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

variable "node_id" {
  type        = number
  default     = null
  nullable    = true
  description = "Optional Phala Cloud node ID. When set, pin every coordinator and workload CVM in the demo to that node."

  validation {
    condition     = var.node_id == null ? true : var.node_id > 0
    error_message = "node_id must be null or a positive Phala Cloud node ID."
  }
}

# Broker URLs are derived from allocated coordinator identities below.
variable "stun_urls" {
  type        = list(string)
  default     = ["stun:stun.cloudflare.com:3478"]
  description = "STUN endpoints for direct ICE traversal. TURN URLs are not supported."
  validation {
    condition     = alltrue([for endpoint in var.stun_urls : can(regex("^stun:[^/?#]+$", endpoint))])
    error_message = "stun_urls must contain STUN URLs, never TURN URLs."
  }
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
  description = "Start the coordinator admission broker and require attested workload CVMs before issuing Consul node and service tokens."
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
  signaling_urls = [for slot_name in local.coordinator_members :
    "https://${trimprefix(phala_app_instance.coordinator[slot_name].instance_id, "0x")}-7000.${phala_app_instance.coordinator[slot_name].gateway_base_domain}"
  ]

  launch_os_image = trimspace(var.os_image) == "" ? null : trimspace(var.os_image)

  mesh_service_default_permissions = {
    service_names      = []
    key_prefixes       = []
    session_write      = false
    agent_read_self    = true
    node_identity_self = false
  }

  workload_groups = {
    webdemo = {
      replicas    = var.webdemo_replicas
      compose     = "${path.module}/compose/webdemo.yaml"
      compose_env = {}
      backends = {
        webdemo = {
          port     = 8080
          workload = "webdemo"
          registration = {
            owner  = "platform"
            parent = "webdemo"
          }
          consul_permissions = {}
        }
      }
      routes = {
        webdemo = {
          backend = "webdemo"
          role    = null
        }
      }
    }

    postgres = {
      replicas = var.postgres_replicas
      compose  = "${path.module}/compose/postgres.yaml"
      # Superuser + replication passwords are derived in-TEE by
      # bootstrap-secrets (postgres replicas share one app_id). This flag
      # turns that on; the values never touch Terraform or state.
      compose_env = {
        DERIVE_PATRONI_PASSWORDS = "1"
      }
      backends = {
        postgres = {
          port     = 5432
          workload = "postgres"
          registration = {
            owner  = "workload"
            parent = var.cluster_name
          }
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

  workload_group_names = sort(keys(local.workload_groups))

  coordinator_compose = yamldecode(file("${path.module}/compose/coordinator.yaml"))
  workload_compose_by_group = {
    for group in local.workload_group_names :
    group => yamldecode(file(local.workload_groups[group].compose))
  }

  coordinator_peers = [
    for i in range(var.coordinator_replicas) : {
      id        = "coordinator-${i}"
      role      = "coordinator"
      ordinal   = i
      slot_name = "${var.cluster_name}-coordinator-${i}"
      vip       = i + 1
    }
  ]

  workload_slot_defs = flatten([
    for group in local.workload_group_names : [
      for i in range(local.workload_groups[group].replicas) : {
        key       = "${group}-${i}"
        group     = group
        role      = group
        ordinal   = i
        id        = "${group}-${i}"
        slot_name = "${var.cluster_name}-${group}-${i + 1}"
      }
    ]
  ])

  workload_peers = [
    for idx, p in local.workload_slot_defs : merge(p, {
      vip = var.coordinator_replicas + idx + 1
    })
  ]

  peers      = concat(local.coordinator_peers, local.workload_peers)
  peers_json = jsonencode([for p in local.peers : { id = p.id, vip = p.vip }])

  # COORDINATOR_VIPS — comma-separated for serf retry-join.
  coordinator_vips = join(",", [for p in local.coordinator_peers : tostring(p.vip)])

  # ---------- Mesh descriptors ----------
  #
  # A workload group is a Phala placement unit: one compose file, one
  # replica count, one app id, and one compose hash. A backend is a real
  # local server process hosted by a workload group. A route is a callable
  # mesh name that applications dial; several routes may select one
  # backend by runtime metadata such as a Patroni role tag.
  backend_declarations = flatten([
    for group in local.workload_group_names : [
      for backend_name, backend in local.workload_groups[group].backends : {
        key                = "${group}/${backend_name}"
        owner              = group
        backend            = backend_name
        port               = backend.port
        workload           = backend.workload
        parent             = backend.registration.parent
        registration_owner = backend.registration.owner
        registers_parent   = backend.registration.owner == "platform"
        consul_permissions = merge(local.mesh_service_default_permissions, backend.consul_permissions)
        admission_identity = "spiffe://${var.cluster_name}/${backend.workload}"
      }
    ]
  ])

  backend_by_key = {
    for backend in local.backend_declarations : backend.key => backend
  }
  backend_keys = sort(keys(local.backend_by_key))

  backends = [
    for idx, key in local.backend_keys : merge(local.backend_by_key[key], {
      sidecar_port = 21000 + idx
    })
  ]
  backends_by_key = {
    for backend in local.backends : backend.key => backend
  }

  route_declarations = flatten([
    for group in local.workload_group_names : [
      for route_name, route in local.workload_groups[group].routes : {
        name    = route_name
        owner   = group
        backend = route.backend
        key     = "${group}/${route.backend}"
        role    = route.role
        subset  = route.role
      }
    ]
  ])
  route_by_name = {
    for route in local.route_declarations : route.name => route
  }
  route_names = sort(keys(local.route_by_name))

  mesh_routes = [
    for idx, name in local.route_names : {
      name               = name
      owner              = local.route_by_name[name].owner
      backend            = local.route_by_name[name].backend
      port               = local.backends_by_key[local.route_by_name[name].key].port
      role               = local.route_by_name[name].role
      subset             = local.route_by_name[name].subset
      vip                = 10 + idx
      parent             = local.backends_by_key[local.route_by_name[name].key].parent
      sidecar_port       = local.backends_by_key[local.route_by_name[name].key].sidecar_port
      registration_owner = local.backends_by_key[local.route_by_name[name].key].registration_owner
      registers_parent   = local.backends_by_key[local.route_by_name[name].key].registers_parent
      admission_identity = local.backends_by_key[local.route_by_name[name].key].admission_identity
    }
  ]

  mesh_routes_json = jsonencode(local.mesh_routes)

  local_backends_json_by_group = {
    for group in local.workload_group_names : group => jsonencode([
      for backend in local.backends : backend if backend.owner == group
    ])
  }

  # ---------- Slot identity (v0.3 named-slot model) ----------
  #
  # `members` carries stable per-CVM names the cloud and Terraform both
  # index by. Workload peer IDs carry the group and a group-local ordinal:
  #
  #   ${cluster}-webdemo-1    -> peer id webdemo-0
  #   ${cluster}-postgres-1   -> peer id postgres-0
  coordinator_members = [for p in local.coordinator_peers : p.slot_name]
  workload_members = {
    for group in local.workload_group_names : group => [
      for p in local.workload_peers : p.slot_name if p.group == group
    ]
  }
  workload_slots_by_name = {
    for p in local.workload_peers : p.slot_name => p
  }
  workload_bootstrap_slot_name = {
    for group in local.workload_group_names : group => local.workload_members[group][0]
  }

  coordinator_ordinals = {
    for p in local.coordinator_peers : p.slot_name => p.ordinal
  }

  # Per-slot env, keyed by slot name (matches `members` entries).
  # `phala_app.env` (bootstrap CVM) reads from this for `members[0]`;
  # `phala_app_instance.env` reads from it for each non-bootstrap slot.
  coordinator_preflight_env = {
    for slot_name, ordinal in local.coordinator_ordinals : slot_name => {
      CLUSTER_NAME            = var.cluster_name
      PEERS_JSON              = local.peers_json
      MESH_ROUTES_JSON        = local.mesh_routes_json
      COORDINATOR_ORDINAL     = tostring(ordinal)
      BOOTSTRAP_EXPECT        = tostring(var.coordinator_replicas)
      COORDINATOR_VIPS        = local.coordinator_vips
      SIGNALING_URLS_JSON     = "[]"
      STUN_URLS_JSON          = jsonencode(var.stun_urls)
      GOSSIP_KEY              = random_bytes.gossip_key.base64
      MESH_CONN_DEBUG_ICE     = var.mesh_conn_debug_ice
      ADMISSION_BROKER_ENABLE = var.enable_attestation_admission ? "1" : ""
      # The env key is part of the compose allowlist, but the policy
      # value is not measured. Keep preflight acyclic by hashing with
      # the same key present and an empty value; the deployed resource
      # receives the generated policy JSON below.
      ADMISSION_POLICY_JSON = ""
    }
  }

  workload_preflight_env_by_slot = {
    for slot_name, slot in local.workload_slots_by_name : slot_name => merge(
      {
        CLUSTER_NAME            = var.cluster_name
        WORKLOAD_GROUP          = slot.group
        WORKLOAD_ORDINAL        = tostring(slot.ordinal)
        EXPECTED_REPLICAS       = tostring(local.workload_groups[slot.group].replicas)
        PEERS_JSON              = local.peers_json
        MESH_ROUTES_JSON        = local.mesh_routes_json
        LOCAL_BACKENDS_JSON     = local.local_backends_json_by_group[slot.group]
        COORDINATOR_VIPS        = local.coordinator_vips
        SIGNALING_URLS_JSON     = "[]"
        STUN_URLS_JSON          = jsonencode(var.stun_urls)
        GOSSIP_KEY              = random_bytes.gossip_key.base64
        MESH_CONN_DEBUG_ICE     = var.mesh_conn_debug_ice
        ADMISSION_BROKER_ENABLE = var.enable_attestation_admission ? "1" : ""
      },
      local.workload_groups[slot.group].compose_env,
    )
  }

  workload_preflight_env_by_group = {
    for group in local.workload_group_names :
    group => local.workload_preflight_env_by_slot[local.workload_bootstrap_slot_name[group]]
  }

  admission_node_identity   = "spiffe://${var.cluster_name}/node"
  admission_egress_identity = "spiffe://${var.cluster_name}/egress"

  admission_node_workloads = [
    for slot in local.workload_peers : {
      workload_id    = "${var.cluster_name}/${slot.group}/${slot.ordinal}/node"
      identity       = local.admission_node_identity
      peer_id        = slot.id
      consul_service = ""
      consul_permissions = {
        service_names      = []
        key_prefixes       = []
        session_write      = false
        agent_read_self    = false
        node_identity_self = true
      }
      allowed_compose_hashes = [phala_app_preflight.workload[slot.group].compose_hash]
    }
  ]

  admission_egress_workloads = [
    for slot in local.workload_peers : {
      workload_id    = "${var.cluster_name}/${slot.group}/${slot.ordinal}/egress"
      identity       = local.admission_egress_identity
      peer_id        = slot.id
      consul_service = "egress-${slot.group}"
      consul_permissions = {
        service_names      = ["egress-${slot.group}-${slot.id}-sidecar"]
        key_prefixes       = []
        session_write      = false
        agent_read_self    = true
        node_identity_self = false
      }
      allowed_compose_hashes = [phala_app_preflight.workload[slot.group].compose_hash]
    }
  ]

  admission_backend_workloads = flatten([
    for slot in local.workload_peers : [
      for backend in local.backends : {
        workload_id            = "${var.cluster_name}/${slot.group}/${slot.ordinal}/${backend.backend}"
        identity               = backend.admission_identity
        peer_id                = slot.id
        consul_service         = backend.parent
        consul_permissions     = backend.consul_permissions
        allowed_compose_hashes = [phala_app_preflight.workload[slot.group].compose_hash]
      } if backend.owner == slot.group
    ]
  ])

  admission_workloads = concat(
    local.admission_node_workloads,
    local.admission_egress_workloads,
    local.admission_backend_workloads,
  )

  admission_policy_json = jsonencode({
    cluster      = var.cluster_name
    policy_epoch = 1
    kms = var.admission_expected_kms_public_key == "" ? null : {
      name = "kms"
      id   = var.admission_expected_kms_public_key
    }
    os_image = var.production_profile ? {
      image = local.launch_os_image
      hash  = phala_app_preflight.workload[local.workload_group_names[0]].os_image_hash
    } : null
    workloads = local.admission_workloads
  })

  coordinator_env_by_slot = {
    for slot_name, env in local.coordinator_preflight_env : slot_name => merge(env, {
      ADMISSION_POLICY_JSON = local.admission_policy_json
      SIGNALING_URLS_JSON   = jsonencode(local.signaling_urls)
    })
  }

  workload_env_by_slot = {
    for slot_name, env in local.workload_preflight_env_by_slot : slot_name => merge(env, {
      SIGNALING_URLS_JSON = jsonencode(local.signaling_urls)
    })
  }
}

# ---------- Workload preflight (group revision evidence) ----------
#
# Each workload group gets its own preflight because each group has a
# distinct compose file and therefore a distinct admission compose hash.

resource "phala_app_preflight" "workload" {
  for_each = local.workload_groups

  name           = local.workload_bootstrap_slot_name[each.key]
  size           = "tdx.small"
  region         = "US-WEST-1"
  node_id        = var.node_id
  image          = local.launch_os_image
  disk_size      = 20
  storage_fs     = "zfs"
  docker_compose = file(each.value.compose)
  env_keys       = sort(keys(local.workload_preflight_env_by_group[each.key]))

  listed         = false
  public_logs    = true
  public_sysinfo = false
}

# ---------- Coordinator app + slots ----------
#
# Single `phala_app.coordinator` owns the coordinator replica set's app
# identity and the bootstrap CVM. The other coordinator slots are
# declared as `phala_app_instance.coordinator` entries; each carries its
# own identity. phala_cvm_env owns each slot's runtime values so
# bootstrap-secrets sees the right COORDINATOR_ORDINAL on every peer.

resource "phala_app" "coordinator" {
  name    = local.coordinator_members[0]
  members = local.coordinator_members

  size           = "tdx.small"
  region         = "US-WEST-1"
  node_id        = var.node_id
  image          = local.launch_os_image
  kms            = var.kms
  disk_size      = 20
  storage_fs     = "zfs" # MUST pin (terraform-provider-phala#5)
  docker_compose = file("${path.module}/compose/coordinator.yaml")

  # Allocate identity with measured keys, but no runtime values. Values
  # belong to phala_cvm_env below, after all broker identities are known.
  env_keys = sort(keys(local.coordinator_preflight_env[local.coordinator_members[0]]))

  listed         = false
  public_logs    = true
  public_sysinfo = false

  wait_for_ready       = false
  wait_timeout_seconds = 600

  lifecycle {
    precondition {
      condition = alltrue([
        for service_name, service in local.coordinator_compose.services :
        !can(regex("\\$\\{", coalesce(try(tostring(service.image), null), "")))
      ])
      error_message = "Coordinator compose service images must be literal strings. Edit the compose file to change images."
    }
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
  for_each = toset(local.coordinator_members)

  app_id = phala_app.coordinator.app_id
  name   = each.value

  # The first slot adopts the bootstrap CVM. All slots, including the
  # bootstrap, receive values through their separate phala_cvm_env resource.

  wait_for_ready       = false
  wait_for_identity    = true
  wait_timeout_seconds = 600
}

resource "phala_cvm_env" "coordinator" {
  for_each = toset(local.coordinator_members)

  cvm_id = phala_app_instance.coordinator[each.key].vm_uuid
  env    = local.coordinator_env_by_slot[each.key]

  wait_for_ready       = true
  wait_timeout_seconds = 600
}

# ---------- Workload apps + slots ----------
#
# Identity allocation has already provided the brokers' endpoint roster.
# Workloads can boot while coordinator environments update. Admission and
# Consul startup wait for their infrastructure at runtime; a Terraform quorum
# barrier would serialize independent CVM boots without adding a data dependency.

resource "phala_app" "workload" {
  for_each = local.workload_groups

  name    = local.workload_bootstrap_slot_name[each.key]
  members = local.workload_members[each.key]

  size           = "tdx.small"
  region         = "US-WEST-1"
  node_id        = var.node_id
  image          = local.launch_os_image
  kms            = var.kms
  disk_size      = 20
  storage_fs     = "zfs"
  docker_compose = file(each.value.compose)

  env = local.workload_env_by_slot[local.workload_bootstrap_slot_name[each.key]]

  env_update_scope = "bootstrap"

  listed         = false
  public_logs    = true
  public_sysinfo = false

  wait_for_ready       = false
  wait_timeout_seconds = 600

  lifecycle {
    precondition {
      condition     = length(local.signaling_urls) > 0
      error_message = "At least one coordinator signaling endpoint is required."
    }
    precondition {
      condition = alltrue(flatten([
        for group in local.workload_group_names : [
          for service_name, service in local.workload_compose_by_group[group].services :
          !can(regex("\\$\\{", coalesce(try(tostring(service.image), null), "")))
        ]
      ]))
      error_message = "Workload compose service images must be literal strings. Edit the compose file to change images."
    }
    precondition {
      condition     = length(local.mesh_routes) == length(distinct([for route in local.mesh_routes : route.name]))
      error_message = "Route names must be globally unique."
    }
    precondition {
      condition = alltrue([
        for backend in local.backends :
        contains(["platform", "workload"], backend.registration_owner)
      ])
      error_message = "Each backend registration.owner must be either \"platform\" or \"workload\"."
    }
    precondition {
      condition = alltrue([
        for backend in local.backends : trimspace(backend.parent) != ""
      ])
      error_message = "Each backend must define a non-empty registration.parent."
    }
    precondition {
      condition = alltrue([
        for group in local.workload_group_names : local.workload_groups[group].replicas > 0
      ])
      error_message = "Each workload group must have at least one slot."
    }
    precondition {
      condition     = length(local.peers) == length(distinct([for p in local.peers : p.id]))
      error_message = "Peer IDs must be globally unique."
    }
    precondition {
      condition     = length(local.mesh_routes) == length(distinct([for route in local.mesh_routes : route.vip]))
      error_message = "Route VIPs must be globally unique."
    }
    precondition {
      condition     = length(local.backends) == length(distinct([for backend in local.backends : backend.sidecar_port]))
      error_message = "Producer sidecar ports must be globally unique."
    }
  }

}

resource "phala_app_instance" "workload" {
  for_each = local.workload_slots_by_name

  app_id = phala_app.workload[each.value.group].app_id
  name   = each.value.slot_name

  env = each.value.slot_name == phala_app.workload[each.value.group].name ? null : local.workload_env_by_slot[each.value.slot_name]

  wait_for_ready       = true
  wait_timeout_seconds = 600
}

# ---------- Outputs ----------

output "coordinator_app_id" { value = phala_app.coordinator.app_id }

output "workload_app_ids" {
  description = "Map of workload group name -> Phala app id."
  value       = { for group, app in phala_app.workload : group => app.app_id }
}

output "webdemo_app_id" { value = phala_app.workload["webdemo"].app_id }

output "coordinator_slot_uuids" {
  description = "Map of stable coordinator slot name -> current vm_uuid. The slot name is durable; vm_uuid may change on CVM replacement."
  value       = { for k, s in phala_app_instance.coordinator : k => s.vm_uuid }
}

output "workload_slot_uuids" {
  description = "Map of stable workload slot name -> current vm_uuid."
  value       = { for k, s in phala_app_instance.workload : k => s.vm_uuid }
}

output "admission_policy_json" { value = local.admission_policy_json }

output "workload_preflight_compose_hashes" {
  value = { for group, w in phala_app_preflight.workload : group => w.compose_hash }
}

output "consul_ui" {
  # Coordinator-0's Consul HTTP API on the canonical 8500. Plain HTTP
  # backend -> use the no-`s` gateway form (gateway terminates TLS).
  value = "https://${trimprefix(phala_app.coordinator.app_id, "app_")}-8500.${phala_app.coordinator.gateway_base_domain}/ui"
}

output "webdemo_url" {
  description = "Public gateway URL for the webdemo workload. Use /hello for one replica and /all to fan out through the mesh."
  value       = "https://${trimprefix(phala_app.workload["webdemo"].app_id, "app_")}-8080.${phala_app.workload["webdemo"].gateway_base_domain}"
}

output "coordinator_signaling_urls" {
  description = "Instance-pinned broker endpoints for independent stores."
  value       = local.signaling_urls
}
