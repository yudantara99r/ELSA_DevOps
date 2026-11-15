#!/bin/sh
# Check the Cloudflare config. No API token and no backend.
# Safe to run again.
set -eu

. "$(CDPATH= cd -- "$(dirname "$0")" && pwd)/lib/reexec.sh"
reexec_in_toolbox "$@"

cd /workspace/cloudflare
terraform fmt -check
terraform init -backend=false -input=false
terraform validate
echo "TERRAFORM_OK"
