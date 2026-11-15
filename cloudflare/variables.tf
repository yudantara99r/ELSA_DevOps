variable "zone_id" {
  type        = string
  description = "Zone that contains example.com."
}

variable "existing_record_id" {
  type        = string
  description = "ID of the quote-api DNS record that was created in the dashboard."
}

variable "origin_ip" {
  type        = string
  description = "Origin address Cloudflare proxies to. 203.0.113.10 is documentation space."
  default     = "203.0.113.10"
}
