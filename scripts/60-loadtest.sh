#!/bin/sh
# Ramp /api/quote through the Ingress and require the HPA to pass 3 replicas.
# Safe to run again. Leaves the deployment back at 3 ready pods.
set -eu

. "$(CDPATH= cd -- "$(dirname "$0")" && pwd)/lib/reexec.sh"
reexec_in_toolbox "$@"

ROOT=/workspace
NS=quote-api
INGRESS_PORT=${INGRESS_PORT:-8080}
BASE_URL="http://host.docker.internal:${INGRESS_PORT}/api/quote"
sampler_pid=
watch_pid=

wait_for_replicas() {
  want=$1
  tries=$2
  i=0
  ready=
  while [ "$i" -lt "$tries" ]; do
    ready=$(kubectl -n "$NS" get deploy quote-api -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
    desired=$(kubectl -n "$NS" get hpa quote-api -o jsonpath='{.status.desiredReplicas}' 2>/dev/null || true)
    if [ "$ready" = "$want" ] && [ "$desired" = "$want" ]; then
      return 0
    fi
    i=$((i + 1))
    sleep 10
  done
  echo "ERROR: quote-api has ${ready:-unknown} ready replicas, wanted ${want}" >&2
  return 1
}

# Scale-down keeps whichever pods were already running, so three pods can all
# sit on spot. Delete one from the heavier pool and let the spread place it.
rebalance() {
  kubectl get nodes -o json > /tmp/rebalance-nodes.json
  kubectl -n "$NS" get pods -l app.kubernetes.io/name=quote-api \
    --field-selector=status.phase=Running -o json > /tmp/rebalance-pods.json
  pod=$(jq -r --slurpfile nodes /tmp/rebalance-nodes.json '
    ($nodes[0].items | map({key: .metadata.name, value: (.metadata.labels["acme.io/capacity"] // "other")}) | from_entries) as $cap
    | [ .items[] | {name: .metadata.name, cap: ($cap[.spec.nodeName] // "other")} ] as $pods
    | ([$pods[] | select(.cap == "spot")] | length) as $spot
    | ([$pods[] | select(.cap == "on-demand")] | length) as $ondemand
    | if $spot > $ondemand then ([$pods[] | select(.cap == "spot")][0].name)
      elif $ondemand > ($spot + 1) then ([$pods[] | select(.cap == "on-demand")][0].name)
      else "" end
  ' /tmp/rebalance-pods.json)
  if [ -n "$pod" ]; then
    kubectl -n "$NS" delete pod "$pod" --wait=false >/dev/null
    wait_for_replicas 3 12
  fi
}

cleanup() {
  status=$?
  trap - EXIT INT TERM
  touch /tmp/loadtest-done
  if [ -n "$sampler_pid" ]; then
    wait "$sampler_pid" 2>/dev/null || true
  fi
  if [ -n "$watch_pid" ]; then
    kill "$watch_pid" 2>/dev/null || true
    wait "$watch_pid" 2>/dev/null || true
  fi
  wait_for_replicas 3 42 || true
  rebalance || true
  exit "$status"
}
trap cleanup EXIT INT TERM

if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
  echo "ERROR: namespace ${NS} is missing. Run scripts/20-deploy.sh first." >&2
  exit 1
fi

kubectl apply -f "$ROOT/monitoring/grafana-ingress.yaml"
kubectl -n monitoring create configmap quote-api-dashboard \
  --from-file=quote-api.json="$ROOT/monitoring/quote-api-dashboard.json" \
  --dry-run=client -o json \
  | jq '.metadata.labels = ((.metadata.labels // {}) + {"grafana_dashboard": "1"})' \
  | kubectl apply -f -

rm -f /tmp/loadtest-done /tmp/loadtest-samples.txt /tmp/hpa-watch.txt /tmp/k6-summary.json
kubectl -n "$NS" get hpa quote-api -w > /tmp/hpa-watch.txt 2>&1 &
watch_pid=$!

(
  while [ ! -f /tmp/loadtest-done ]; do
    kubectl get nodes -o json > /tmp/loadtest-nodes.json
    kubectl -n "$NS" get pods -l app.kubernetes.io/name=quote-api \
      --field-selector=status.phase=Running -o json > /tmp/loadtest-pods.json
    jq -nr --slurpfile nodes /tmp/loadtest-nodes.json --slurpfile pods /tmp/loadtest-pods.json '
      ($nodes[0].items | map({key: .metadata.name, value: (.metadata.labels["acme.io/capacity"] // "other")}) | from_entries) as $cap
      | ($pods[0].items | map($cap[.spec.nodeName] // "other")) as $places
      | [$places[] | select(. == "spot")] | length as $spot
      | [$places[] | select(. == "on-demand")] | length as $ondemand
      | [$places[] | select(. != "spot" and . != "on-demand")] | length as $other
      | "\($spot) \($ondemand) \($other)"
    ' >> /tmp/loadtest-samples.txt
    sleep 5
  done
) &
sampler_pid=$!

echo "Waiting for quote-api to settle at 3 replicas"
wait_for_replicas 3 36
rebalance

echo "Running k6 against ${BASE_URL}"
BASE_URL="$BASE_URL" k6 run --summary-export=/tmp/k6-summary.json "$ROOT/loadtest/quote.js"
touch /tmp/loadtest-done
wait "$sampler_pid" 2>/dev/null || true
sampler_pid=

p95=$(jq -r '.metrics.http_req_duration["p(95)"]' /tmp/k6-summary.json)
failed=$(jq -r '.metrics.http_req_failed.value' /tmp/k6-summary.json)
rate=$(jq -r '.metrics.http_reqs.rate' /tmp/k6-summary.json)
echo "k6 p95_ms=${p95} failed_rate=${failed} rps=${rate}"

if ! awk '
  ($1 + $2) == 3 && $3 == 0 { saw3 = 1 }
  saw3 && ($1 + $2) > 3 && $3 == 0 {
    diff = $1 - $2
    if (diff < 0) diff = -diff
    if ($1 > 0 && $2 > 0 && diff <= 1) ok = 1
  }
  END { exit !ok }
' /tmp/loadtest-samples.txt; then
  echo "ERROR: HPA did not scale past 3 on spot and on-demand" >&2
  cat /tmp/loadtest-samples.txt >&2
  exit 1
fi

echo "LOADTEST_OK"
