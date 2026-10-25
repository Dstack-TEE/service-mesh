terraform {
  required_version = ">= 1.5"
  required_providers {
    phala = {
      source = "phala-network/phala"
    }
  }
}

locals {
  members = sort(keys(var.instances))
  env_keys = sort(distinct(concat(
    keys(var.env),
    flatten([for instance in var.instances : keys(instance.env)]),
    ["SIGNALING_URLS_JSON"],
  )))
  signaling_urls = [for name in local.members :
    "https://${trimprefix(phala_app_instance.this[name].instance_id, "0x")}-7000.${phala_app_instance.this[name].gateway_base_domain}"
  ]
}

resource "phala_app" "this" {
  name           = var.bootstrap_name
  members        = local.members
  node_id        = var.bootstrap_node_id == null ? var.instances[var.bootstrap_name].node_id : var.bootstrap_node_id
  size           = var.size
  region         = var.region
  image          = var.image
  kms            = var.kms
  disk_size      = var.disk_size
  storage_fs     = "zfs"
  docker_compose = var.docker_compose
  env_keys       = local.env_keys

  listed         = false
  public_logs    = true
  public_sysinfo = false

  wait_for_ready       = false
  wait_timeout_seconds = var.wait_timeout_seconds

  lifecycle {
    precondition {
      condition     = contains(local.members, var.bootstrap_name)
      error_message = "bootstrap_name must identify one of the configured instances."
    }
    precondition {
      condition = contains(local.members, var.bootstrap_name) ? (
        var.bootstrap_node_id == null || var.instances[var.bootstrap_name].node_id == null ||
        var.bootstrap_node_id == var.instances[var.bootstrap_name].node_id
      ) : true
      error_message = "bootstrap_node_id must agree with the bootstrap instance's node_id when both are set."
    }
    precondition {
      condition = alltrue([
        for service in yamldecode(var.docker_compose).services :
        !can(regex("\\$\\{", coalesce(try(tostring(service.image), null), "")))
      ])
      error_message = "Coordinator compose service images must be literal strings."
    }
  }
}

resource "phala_app_instance" "this" {
  for_each = toset(local.members)

  app_id  = phala_app.this.app_id
  name    = each.key
  node_id = var.instances[each.key].node_id

  wait_for_ready       = false
  wait_for_identity    = true
  wait_timeout_seconds = var.wait_timeout_seconds
}

resource "phala_cvm_env" "this" {
  for_each = toset(local.members)

  cvm_id = phala_app_instance.this[each.key].vm_uuid
  env = merge(var.env, var.instances[each.key].env, {
    SIGNALING_URLS_JSON = jsonencode(local.signaling_urls)
  })

  wait_for_ready       = true
  wait_timeout_seconds = var.wait_timeout_seconds
}
