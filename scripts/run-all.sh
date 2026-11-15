#!/bin/sh
# Reviewer entrypoint. Later commits append the numbered scripts in order.
set -eu

. "$(CDPATH= cd -- "$(dirname "$0")" && pwd)/lib/reexec.sh"
reexec_in_toolbox "$@"

script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
sh "$script_dir/00-bootstrap.sh"
sh "$script_dir/20-deploy.sh"
sh "$script_dir/25-reclaim-drill.sh"
