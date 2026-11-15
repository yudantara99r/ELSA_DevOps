#!/bin/sh
# Build the quote-api image on the local Docker engine. Not part of run-all:
# the reviewer pulls the published GHCR image.
set -eu

cd "$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tag=${IMAGE_TAG:-dev}
docker build -t "quote-api:${tag}" .
