terraform {
  required_version = ">= 1.17.2"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.29.0"
    }
  }
}

# Apply reads CLOUDFLARE_API_TOKEN from the environment. Validate does not.
provider "cloudflare" {}
