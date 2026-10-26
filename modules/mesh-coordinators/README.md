# Mesh coordinators

Use this module to configure named coordinator CVMs in one Terraform apply.
It derives the signaling roster internally, so environment inputs never need
to reference the module's own outputs. Requires a Phala provider build with
`phala_cvm_env`, allowlist-only `env_keys`, and `wait_for_identity` (provider
PR #28). These are not in published `0.3.0-beta.4`.

```hcl
module "coordinators" {
  source = "../../modules/mesh-coordinators"

  bootstrap_name = "coordinator-0"
  docker_compose = file("compose/coordinator.yaml")
  env = {
    CLUSTER_NAME = var.cluster_name
    GOSSIP_KEY   = random_bytes.gossip_key.base64
  }
  instances = {
    coordinator-0 = {
      node_id = 38
      env     = { COORDINATOR_ORDINAL = "0" }
    }
    coordinator-1 = {
      node_id = 39
      env     = { COORDINATOR_ORDINAL = "1" }
    }
  }
}
```

Per-instance values override shared `env`. The module reserves
`SIGNALING_URLS_JSON`; do not supply it or feed `module.coordinators.signaling_urls`
back into an input. Keep instance names known and non-sensitive during planning.
`bootstrap_name` must name one instance and should remain unchanged when scaling.

The app declares the union of allowed keys, then the module allocates slots
and configures each CVM's values, including the adopted bootstrap slot.
`signaling_urls` depends only on identities, so workloads can boot while
coordinator environments update. The final apply waits for coordinator CVM
readiness, not admission, mesh connectivity, or application health.

Defaults match the examples: `tdx.small`, `US-WEST-1`, 20 GiB ZFS disks, public
logs enabled, public sysinfo/listing disabled, `phala` KMS, and a 600-second wait
timeout. Optional inputs are `size`, `region`, `disk_size`, `image`, `kms`, and
`wait_timeout_seconds`. Outputs are `app_id`, `gateway_base_domain`, `slot_uuids`,
and `signaling_urls`.

Environment plaintext remains in Terraform state. Protect the state backend.
External value edits cannot be detected through Cloud plaintext readback.
Removing only an environment binding does not clear retained values. Removing
the whole module destroys its managed CVMs.

Both examples include `moved` blocks for the old coordinator app, named slots,
and environment resources. Keep those blocks and preserve names/placement when
migrating. Back up state, run `terraform init`, and inspect the plan for unexpected
replacements. See [deployment and migration](../../docs/signaling.md).

For legacy app-only placement, set `bootstrap_node_id` and leave the adopted
bootstrap entry's `node_id` unset. This preserves the app's pin without adding
a replacement-triggering placement input to the slot binding. When both are
configured, their values must agree.

For local checks, select the unreleased provider through `TF_CLI_CONFIG_FILE`:

```bash
terraform -chdir=modules/mesh-coordinators get
terraform -chdir=modules/mesh-coordinators test
```

The eleven mock-provider tests were checked with Terraform 1.9.8 and do not
create Cloud resources. They cover env merging, roster injection, allowlists, placement,
bootstrap selection, invalid inputs, and unknown sensitive values.
