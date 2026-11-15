#!/bin/sh
# Create a 4-worker k3d cluster, point kubectl at it, and run the provided
# nodepool prep. Safe to run again: an existing healthy cluster is reused.
set -eu

. "$(CDPATH= cd -- "$(dirname "$0")" && pwd)/lib/reexec.sh"
reexec_in_toolbox "$@"

CLUSTER=${CLUSTER_NAME:-elsa}
AGENTS=${K3D_AGENTS:-4}
API_PORT=${API_PORT:-6550}
INGRESS_PORT=${INGRESS_PORT:-8080}
K3S_IMAGE=${K3S_IMAGE:-rancher/k3s:v1.37.2-k3s1}
TOOLBOX=${TOOLBOX_NAME:-elsa-toolbox}

case "$AGENTS" in
  ''|*[!0-9]*)
    echo "ERROR: K3D_AGENTS must be an integer" >&2
    exit 1
    ;;
esac
if [ "$AGENTS" -lt 4 ]; then
  echo "ERROR: K3D_AGENTS must be at least 4" >&2
  exit 1
fi

mkdir -p /tmp
exec 9>/tmp/elsa-bootstrap.lock
flock 9

server="k3d-${CLUSTER}-server-0"
network="k3d-${CLUSTER}"

cluster_json=$(k3d cluster list -o json)
exists=$(printf '%s' "$cluster_json" | jq -r --arg name "$CLUSTER" 'map(select(.name == $name)) | length')
if [ "$exists" != "0" ]; then
  agents_found=$(printf '%s' "$cluster_json" | jq -r --arg name "$CLUSTER" '.[] | select(.name == $name) | .agentsCount')
  running=$(printf '%s' "$cluster_json" | jq -r --arg name "$CLUSTER" '.[] | select(.name == $name) | .agentsRunning')
  if [ "$agents_found" != "$AGENTS" ]; then
    echo "ERROR: cluster ${CLUSTER} has ${agents_found} agents, want ${AGENTS}." >&2
    echo "Remove it with: k3d cluster delete ${CLUSTER}" >&2
    exit 1
  fi
  if [ "$running" != "$AGENTS" ]; then
    echo "Starting cluster ${CLUSTER}"
    k3d cluster start "$CLUSTER"
  else
    echo "Cluster ${CLUSTER} already exists"
  fi
else
  echo "Creating cluster ${CLUSTER} with ${AGENTS} workers"
  k3d cluster create "$CLUSTER" \
    --image "$K3S_IMAGE" \
    --agents "$AGENTS" \
    --servers 1 \
    --api-port "${API_PORT}" \
    --port "${INGRESS_PORT}:80@loadbalancer" \
    --k3s-arg "--tls-san=host.docker.internal@server:0" \
    --k3s-arg "--tls-san=${server}@server:0" \
    --wait \
    --timeout 300s
fi

on_network=$(docker inspect "$TOOLBOX" | jq -r --arg net "$network" '.[0].NetworkSettings.Networks[$net] != null')
if [ "$on_network" != "true" ]; then
  docker network connect "$network" "$TOOLBOX"
fi

ip=$(docker inspect "$server" | jq -r --arg net "$network" '.[0].NetworkSettings.Networks[$net].IPAddress')
if [ -z "$ip" ] || [ "$ip" = "null" ]; then
  echo "ERROR: ${server} has no IP on ${network}" >&2
  exit 1
fi
grep -v "[[:space:]]${server}$" /etc/hosts > /tmp/hosts.elsa || true
printf '%s %s\n' "$ip" "$server" >> /tmp/hosts.elsa
cat /tmp/hosts.elsa > /etc/hosts

mkdir -p /root/.kube
k3d kubeconfig get "$CLUSTER" > /root/.kube/config
sed -i "s#server: https://.*#server: https://${server}:6443#" /root/.kube/config
chmod 600 /root/.kube/config

echo "Waiting for the API at https://${server}:6443"
i=0
until kubectl get --raw=/readyz >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 30 ]; then
    echo "ERROR: API server did not become ready" >&2
    exit 1
  fi
  sleep 2
done

echo "Waiting for nodes"
if ! kubectl wait --for=condition=Ready node --all --timeout=180s; then
  kubectl get nodes -o wide >&2 || true
  exit 1
fi

echo "Applying nodepool labels"
sh /workspace/troubleshoot/prepare.sh

spot=$(kubectl get nodes -l acme.io/capacity=spot --no-headers | wc -l | tr -d ' ')
ondemand=$(kubectl get nodes -l acme.io/capacity=on-demand --no-headers | wc -l | tr -d ' ')
gpu=$(kubectl get nodes -l acme.io/node-type=gpu --no-headers | wc -l | tr -d ' ')
taint=$(kubectl get nodes -l acme.io/node-type=gpu -o jsonpath='{.items[0].spec.taints[*].key}')

if [ "$spot" -lt 2 ] || [ "$ondemand" -lt 1 ] || [ "$gpu" -lt 1 ]; then
  echo "ERROR: nodepool labels are incomplete (spot=${spot} on-demand=${ondemand} gpu=${gpu})" >&2
  kubectl get nodes -L acme.io/capacity -L acme.io/node-type >&2 || true
  exit 1
fi
case "$taint" in
  *nvidia.com/gpu*) ;;
  *)
    echo "ERROR: GPU node is missing the nvidia.com/gpu taint" >&2
    exit 1
    ;;
esac

echo "BOOTSTRAP_OK"
