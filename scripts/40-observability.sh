#!/bin/sh
# Install kube-prometheus-stack and scrape quote-api /metrics.
# Safe to run again. Requires the quote-api namespace from scripts/20-deploy.sh.
set -eu

. "$(CDPATH= cd -- "$(dirname "$0")" && pwd)/lib/reexec.sh"
reexec_in_toolbox "$@"

CHART_VERSION=${PROM_CHART_VERSION:-93.3.0}
ROOT=/workspace
PROM_URL=http://127.0.0.1:19090
pf_pid=

cleanup() {
  if [ -n "$pf_pid" ]; then
    kill "$pf_pid" 2>/dev/null || true
    wait "$pf_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

if ! kubectl get namespace quote-api >/dev/null 2>&1; then
  echo "ERROR: namespace quote-api is missing. Run scripts/20-deploy.sh first." >&2
  exit 1
fi

echo "Installing kube-prometheus-stack ${CHART_VERSION}"
if ! helm repo list -o json | jq -e '.[] | select(.name == "prometheus-community")' >/dev/null; then
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
fi
helm repo update
# --wait stops at the Deployment progress deadline. A cold Grafana pull on a
# small link takes longer than the 600s default, so the deadline is raised
# and the rollouts are waited on here.
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version "$CHART_VERSION" \
  --namespace monitoring \
  --create-namespace \
  --values "$ROOT/monitoring/values.yaml" \
  --timeout 15m
kubectl -n monitoring patch deployment kube-prometheus-stack-grafana --type=merge \
  -p '{"spec":{"progressDeadlineSeconds":1800}}'
kubectl -n monitoring rollout status deployment/kube-prometheus-stack-operator --timeout=600s
kubectl -n monitoring rollout status deployment/kube-prometheus-stack-kube-state-metrics --timeout=600s
kubectl -n monitoring rollout status daemonset/kube-prometheus-stack-prometheus-node-exporter --timeout=600s
kubectl -n monitoring rollout status statefulset/prometheus-kube-prometheus-stack-prometheus --timeout=600s
kubectl -n monitoring rollout status deployment/kube-prometheus-stack-grafana --timeout=1800s

kubectl -n monitoring get prometheus -o json > /tmp/obs-prometheus.json
jq -e '.items[0].spec.serviceMonitorSelector == {}' /tmp/obs-prometheus.json >/dev/null
jq -e '.items[0].spec.serviceMonitorNamespaceSelector == {}' /tmp/obs-prometheus.json >/dev/null
jq -e '.items[0].spec.ruleSelector == {}' /tmp/obs-prometheus.json >/dev/null
jq -e '.items[0].spec.ruleNamespaceSelector == {}' /tmp/obs-prometheus.json >/dev/null

kubectl apply -f "$ROOT/monitoring/quote-api.yaml"

# The process emits /api/quote only after that path has been served.
curl -fsS "http://host.docker.internal:${INGRESS_PORT:-8080}/api/quote" >/dev/null

kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090 >/tmp/obs-port-forward.log 2>&1 &
pf_pid=$!

i=0
while [ "$i" -lt 30 ]; do
  if curl -fsS -G "$PROM_URL/api/v1/query" --data-urlencode 'query=up' >/dev/null 2>&1; then
    break
  fi
  i=$((i + 1))
  sleep 1
done

echo "Waiting for quote_requests_total"
i=0
while [ "$i" -lt 36 ]; do
  if curl -fsS -G "$PROM_URL/api/v1/query" \
      --data-urlencode 'query=quote_requests_total{namespace="quote-api",path="/api/quote"}' \
      > /tmp/obs-query.json \
    && jq -e '.data.result | length > 0' /tmp/obs-query.json >/dev/null; then
    break
  fi
  i=$((i + 1))
  sleep 5
done
if ! jq -e '.data.result | length > 0' /tmp/obs-query.json >/dev/null; then
  echo "ERROR: Prometheus has not scraped quote_requests_total" >&2
  cat /tmp/obs-query.json >&2 || true
  exit 1
fi

curl -fsS "$PROM_URL/api/v1/rules" > /tmp/obs-rules.json
if ! jq -e '.data.groups[] | select(.name == "quote-api") | .rules[] | select(.name == "QuoteApiErrors")' \
    /tmp/obs-rules.json >/dev/null; then
  echo "ERROR: Prometheus has not loaded QuoteApiErrors" >&2
  exit 1
fi

echo "OBSERVABILITY_OK"
