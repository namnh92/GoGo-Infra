output "tunnel_id" {
  description = "Tunnel id, also the CNAME target."
  value       = cloudflare_zero_trust_tunnel_cloudflared.this.id
}

output "tunnel_token" {
  description = "Token the connector authenticates with, empty unless read_connector_token is on. Sensitive: it is enough to run a connector for this tunnel."
  value       = try(data.cloudflare_zero_trust_tunnel_cloudflared_token.this[0].token, "")
  sensitive   = true
}

output "hostnames" {
  description = "Hostnames routed through the tunnel."
  value       = keys(var.ingress)
}
