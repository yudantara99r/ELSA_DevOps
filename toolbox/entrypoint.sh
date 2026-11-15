#!/bin/sh
# Bring the cluster up before the container is considered idle, then stay running
# so the reviewer can exec the numbered scripts.
set -eu
sh /workspace/scripts/00-bootstrap.sh
exec sleep infinity
