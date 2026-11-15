resource "cloudflare_dns_record" "quote_api" {
  zone_id = var.zone_id
  name    = "quote-api.example.com"
  type    = "A"
  content = var.origin_ip
  ttl     = 1
  proxied = true
}

import {
  to = cloudflare_dns_record.quote_api
  id = "${var.zone_id}/${var.existing_record_id}"
}

resource "cloudflare_ruleset" "cache" {
  zone_id     = var.zone_id
  name        = "quote-api cache"
  description = "Bypass /api and cache static assets."
  kind        = "zone"
  phase       = "http_request_cache_settings"

  # Later rules win when more than one matches.
  rules = [
    {
      ref         = "cache_static"
      description = "Cache static assets for a month at the edge."
      expression  = <<-EOT
        (
          http.host eq "quote-api.example.com" and
          (
            starts_with(http.request.uri.path, "/assets/") or
            ends_with(http.request.uri.path, ".css") or
            ends_with(http.request.uri.path, ".js") or
            ends_with(http.request.uri.path, ".png") or
            ends_with(http.request.uri.path, ".svg") or
            ends_with(http.request.uri.path, ".woff2")
          )
        )
      EOT
      action      = "set_cache_settings"
      action_parameters = {
        cache = true
        edge_ttl = {
          mode    = "override_origin"
          default = 2592000
        }
        browser_ttl = {
          mode    = "override_origin"
          default = 604800
        }
      }
    },
    {
      ref         = "bypass_api"
      description = "Do not cache API responses."
      expression  = <<-EOT
        (
          http.host eq "quote-api.example.com" and
          starts_with(http.request.uri.path, "/api/")
        )
      EOT
      action      = "set_cache_settings"
      action_parameters = {
        cache = false
        browser_ttl = {
          mode = "bypass_by_default"
        }
      }
    },
  ]
}
