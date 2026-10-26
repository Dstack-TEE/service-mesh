output "app_id" {
  value = phala_app.this.app_id
}

output "gateway_base_domain" {
  value = phala_app.this.gateway_base_domain
}

output "slot_uuids" {
  value = { for name, instance in phala_app_instance.this : name => instance.vm_uuid }
}

output "signaling_urls" {
  description = "Instance-pinned broker URLs, available after identity allocation without waiting for environment updates."
  value       = local.signaling_urls
}
