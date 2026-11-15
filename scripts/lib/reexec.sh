#!/bin/sh
# Run the calling script inside the toolbox when it was started from the host.
# $0 stays the caller's path because this file is sourced.
reexec_in_toolbox() {
  if [ "${IN_TOOLBOX:-}" = "1" ]; then
    return 0
  fi
  root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
  script="./scripts/$(basename "$0")"
  cd "$root"
  # Git Bash would rewrite "/workspace" into a Windows path. Linux ignores this.
  export MSYS_NO_PATHCONV=1
  exec docker compose exec -T -w /workspace toolbox sh "$script" "$@"
}
