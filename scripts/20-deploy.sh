#!/bin/sh
# Install Argo CD and let it sync the quote-api chart from git.
# Safe to run again.
set -eu

. "$(CDPATH= cd -- "$(dirname "$0")" && pwd)/lib/reexec.sh"
reexec_in_toolbox "$@"

CLUSTER=${CLUSTER_NAME:-elsa}
INGRESS_PORT=${INGRESS_PORT:-8080}
ARGO_CHART_VERSION=${ARGO_CHART_VERSION:-10.18.0}
ROOT=/workspace
VALUES="$ROOT/charts/quote-api/values.yaml"
APP="$ROOT/cluster/quote-api-application.yaml"

repository=$(awk '/^image:/{found=1} found && /^  repository:/{print $2; exit}' "$VALUES")
tag=$(awk '/^image:/{found=1} found && /^  tag:/{gsub(/"/, "", $2); print $2; exit}' "$VALUES")
if [ -z "$repository" ] || [ -z "$tag" ]; then
  echo "ERROR: image repository or tag is missing from $VALUES" >&2
  exit 1
fi
ref="${repository}:${tag}"

if ! docker image inspect "$ref" >/dev/null 2>&1; then
  echo "Building ${ref}"
  docker build -t "$ref" "$ROOT"
fi
echo "Importing ${ref} into k3d cluster ${CLUSTER}"
k3d image import "$ref" -c "$CLUSTER"

echo "Installing Argo CD ${ARGO_CHART_VERSION}"
if ! helm repo list -o json | jq -e '.[] | select(.name == "argo")' >/dev/null; then
  helm repo add argo https://argoproj.github.io/argo-helm
fi
helm repo update
# Chart 10.18.0 always installs the ApplicationSet controller.
# Dex and notifications still have enabled flags.
helm upgrade --install argocd argo/argo-cd \
  --version "$ARGO_CHART_VERSION" \
  --namespace argocd \
  --create-namespace \
  --set dex.enabled=false \
  --set notifications.enabled=false \
  --wait \
  --timeout 10m

repo=${GIT_REPO:-$(git -C "$ROOT" remote get-url origin)}
rev=${GIT_REVISION:-$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)}
if [ "$rev" = "HEAD" ]; then
  rev=$(git -C "$ROOT" rev-parse HEAD)
fi

sed \
  -e "s#repoURL:.*#repoURL: ${repo}#" \
  -e "s#targetRevision:.*#targetRevision: ${rev}#" \
  "$APP" > /tmp/quote-api-application.yaml
kubectl apply -f /tmp/quote-api-application.yaml

echo "Waiting for quote-api to become Healthy"
i=0
while [ "$i" -lt 60 ]; do
  sync=$(kubectl -n argocd get application quote-api -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
  health=$(kubectl -n argocd get application quote-api -o jsonpath='{.status.health.status}' 2>/dev/null || true)
  if [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; then
    break
  fi
  i=$((i + 1))
  sleep 5
done
if [ "$sync" != "Synced" ] || [ "$health" != "Healthy" ]; then
  echo "ERROR: application is sync=${sync:-unknown} health=${health:-unknown}" >&2
  kubectl -n argocd get application quote-api -o yaml >&2 || true
  exit 1
fi

kubectl -n quote-api rollout status deployment/quote-api --timeout=180s

spot=0
ondemand=0
other=0
pods=$(kubectl -n quote-api get pods -l app.kubernetes.io/name=quote-api --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}')
printf '%s\n' "$pods"
while read -r pod node; do
  [ -n "$pod" ] || continue
  cap=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.acme\.io/capacity}')
  case "$cap" in
    spot) spot=$((spot + 1)) ;;
    on-demand) ondemand=$((ondemand + 1)) ;;
    *) other=$((other + 1)) ;;
  esac
  echo "$pod $node $cap"
done <<EOF
$pods
EOF

if [ "$other" -ne 0 ] || [ "$spot" -ne 2 ] || [ "$ondemand" -ne 1 ]; then
  echo "ERROR: expected 2 spot and 1 on-demand, got spot=${spot} on-demand=${ondemand} other=${other}" >&2
  exit 1
fi

echo "Checking ingress on port ${INGRESS_PORT}"
i=0
while [ "$i" -lt 30 ]; do
  if curl -fsS "http://host.docker.internal:${INGRESS_PORT}/api/quote"; then
    echo
    echo "DEPLOY_OK"
    exit 0
  fi
  i=$((i + 1))
  sleep 2
done
echo "ERROR: quote endpoint did not answer on port ${INGRESS_PORT}" >&2
exit 1
