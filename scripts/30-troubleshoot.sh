#!/bin/sh
# Apply the broken manifests, replace them with the fix, and run verify.sh.
# Safe to run again. The provided files are not modified.
set -eu

. "$(CDPATH= cd -- "$(dirname "$0")" && pwd)/lib/reexec.sh"
reexec_in_toolbox "$@"

ROOT=/workspace

echo "Applying broken manifests"
kubectl apply -f "$ROOT/troubleshoot/broken-app.yaml"
echo "Applying fixed manifests"
kubectl apply -f "$ROOT/troubleshoot/fixed-app.yaml"

kubectl -n troubleshoot rollout status deployment/web --timeout=180s
kubectl -n troubleshoot rollout status deployment/ai-inference --timeout=180s

sh "$ROOT/troubleshoot/verify.sh"
echo "TROUBLESHOOT_OK"
