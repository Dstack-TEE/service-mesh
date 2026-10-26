terraform {
  required_providers {
    phala = {
      source = "phala-network/phala"
    }
  }
}

variable "bootstrap_name" { type = string }
variable "docker_compose" { type = string }
variable "instances" { type = any }
variable "env" { type = map(string) }

resource "terraform_data" "secret" {
  input = "created-at-apply"
}

module "coordinators" {
  source = "../.."

  bootstrap_name = var.bootstrap_name
  docker_compose = var.docker_compose
  instances      = var.instances
  env = merge(var.env, {
    UNKNOWN_SECRET = sensitive(terraform_data.secret.output)
  })
}
