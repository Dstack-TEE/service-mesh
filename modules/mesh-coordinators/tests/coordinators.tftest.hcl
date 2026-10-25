mock_provider "phala" {
  mock_resource "phala_app" {
    defaults = {
      app_id              = "app_1111111111111111111111111111111111111111"
      gateway_base_domain = "gateway.example"
    }
  }
}

override_resource {
  target = phala_app_instance.this["coord-0"]
  values = {
    instance_id         = "0xaa"
    vm_uuid             = "vm-zero"
    gateway_base_domain = "gateway.example"
  }
}

override_resource {
  target = phala_app_instance.this["coord-1"]
  values = {
    instance_id         = "0xbb"
    vm_uuid             = "vm-one"
    gateway_base_domain = "gateway.example"
  }
}

variables {
  bootstrap_name = "coord-0"
  docker_compose = "services:\n  app:\n    image: example@sha256:abc\n"
  env = {
    SHARED = "shared"
    SECRET = sensitive("secret")
  }
  instances = {
    coord-0 = { node_id = 38, env = { SHARED = "local", COORDINATOR_ORDINAL = "0" } }
    coord-1 = { node_id = 39, env = { COORDINATOR_ORDINAL = "1", EXTRA = "slot-one" } }
  }
}

run "allocate_and_configure" {
  command = apply

  assert {
    condition     = output.signaling_urls == ["https://aa-7000.gateway.example", "https://bb-7000.gateway.example"]
    error_message = "The module must derive a stable, instance-pinned roster."
  }
  assert {
    condition     = phala_app.this.node_id == 38 && phala_app_instance.this["coord-1"].node_id == 39
    error_message = "Bootstrap and other slot placement must match the configured nodes."
  }
  assert {
    condition     = phala_app.this.env == null && phala_app_instance.this["coord-0"].env == null && phala_app_instance.this["coord-1"].env == null
    error_message = "Allocation resources must not also own runtime values."
  }
  assert {
    condition     = phala_app.this.env_keys == tolist(["COORDINATOR_ORDINAL", "EXTRA", "SECRET", "SHARED", "SIGNALING_URLS_JSON"])
    error_message = "The allowlist must include the union of shared, slot, and generated keys."
  }
  assert {
    condition     = phala_cvm_env.this["coord-0"].cvm_id == "vm-zero" && phala_cvm_env.this["coord-1"].cvm_id == "vm-one"
    error_message = "Each environment must target its own allocated CVM."
  }
  assert {
    condition     = phala_cvm_env.this["coord-0"].env.SHARED == "local" && phala_cvm_env.this["coord-1"].env.SHARED == "shared" && phala_cvm_env.this["coord-1"].env.EXTRA == "slot-one"
    error_message = "Per-slot values must override shared values without dropping other keys."
  }
  assert {
    condition     = phala_cvm_env.this["coord-0"].env.SIGNALING_URLS_JSON == jsonencode(output.signaling_urls) && phala_cvm_env.this["coord-1"].env.SIGNALING_URLS_JSON == jsonencode(output.signaling_urls)
    error_message = "Every coordinator must receive the same generated roster."
  }
  assert {
    condition     = !phala_app.this.wait_for_ready && !phala_app_instance.this["coord-0"].wait_for_ready && phala_app_instance.this["coord-0"].wait_for_identity && phala_cvm_env.this["coord-0"].wait_for_ready
    error_message = "Wait for identities during allocation and readiness only after configuration."
  }
}

run "explicit_bootstrap" {
  command = plan
  variables {
    bootstrap_name = "coord-1"
  }
  assert {
    condition     = phala_app.this.name == "coord-1" && phala_app.this.node_id == 39
    error_message = "The bootstrap must be explicit, not chosen by lexical order."
  }
}

run "reject_missing_bootstrap" {
  command = plan
  variables {
    bootstrap_name = "missing"
  }
  expect_failures = [phala_app.this]
}

run "reject_empty_group" {
  command = plan
  variables {
    instances = {}
  }
  expect_failures = [var.instances]
}

run "reject_reserved_shared_key" {
  command = plan
  variables {
    env = { SIGNALING_URLS_JSON = "[]" }
  }
  expect_failures = [var.env]
}

run "reject_reserved_slot_key" {
  command = plan
  variables {
    instances = { coord-0 = { env = { SIGNALING_URLS_JSON = "[]" } } }
  }
  expect_failures = [var.instances]
}

run "reject_dynamic_image" {
  command = plan
  variables {
    docker_compose = "services:\n  app:\n    image: $${IMAGE}\n"
  }
  expect_failures = [phala_app.this]
}

run "unknown_sensitive_values" {
  command = plan
  providers = {
    phala = phala
  }
  module {
    source = "./tests/unknown-env"
  }
}

run "reject_invalid_timeout" {
  command = plan
  variables {
    wait_timeout_seconds = 0
  }
  expect_failures = [var.wait_timeout_seconds]
}

run "legacy_app_only_placement" {
  command = plan
  variables {
    bootstrap_node_id = 42
    instances = {
      coord-0 = { env = { COORDINATOR_ORDINAL = "0" } }
      coord-1 = { node_id = 39, env = { COORDINATOR_ORDINAL = "1" } }
    }
  }
  assert {
    condition     = phala_app.this.node_id == 42 && phala_app_instance.this["coord-0"].node_id == null
    error_message = "Legacy app placement must not introduce a new placement input on the adopted slot."
  }
}

run "reject_conflicting_bootstrap_placement" {
  command = plan
  variables {
    bootstrap_node_id = 42
  }
  expect_failures = [phala_app.this]
}
