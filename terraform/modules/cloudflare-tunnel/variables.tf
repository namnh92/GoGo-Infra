variable "environment" {
  description = "Environment name, used in the tunnel name."
  type        = string
}

variable "account_id" {
  description = "Cloudflare account id."
  type        = string
}

variable "zone_id" {
  description = "Cloudflare zone id for the hostnames routed through the tunnel."
  type        = string
}

variable "ingress" {
  description = "Hostname to origin mapping, e.g. { \"api-dev.gogo.id.vn\" = \"http://api:3000\" }. The origin is resolved from inside the host running cloudflared, so a container name works when cloudflared shares the network."
  type        = map(string)

  validation {
    condition     = length(var.ingress) > 0
    error_message = "At least one hostname is required; a tunnel with no ingress routes nothing."
  }
}

variable "read_connector_token" {
  description = "Fetch the connector credential. Off by default: every plan would otherwise call GET /cfd_tunnel/{id}/token, so the read-only plan token would need permission to read a credential that is enough to run a connector for this tunnel. Turn it on for the one apply that stores or rotates the token."
  type        = bool
  default     = false
}
