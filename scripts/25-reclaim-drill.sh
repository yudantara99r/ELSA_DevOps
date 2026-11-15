#!/bin/sh
# Drain one spot node and prove quote-api keeps answering.
# Safe to run again. The drained node is uncordoned on exit.
#
# Hostname spread is ScheduleAnyway. The cordoned node stays a hostname
# domain with zero pods, so a hard maxSkew of 1 would leave the replacement Pending.
set -eu

. "$(CDPATH= cd -- "$(dirname "$0")" && pwd)/lib/reexec.sh"
reexec_in_toolbox "$@"

INGRESS_PORT=${INGRESS_PORT:-8080}
NS=quote-api
STOP=/tmp/quote-reclaim-stop
OK=/tmp/quote-reclaim-ok
FAIL=/tmp/quote-reclaim-fail
URL="http://host.docker.internal:${INGRESS_PORT}/api/quote"

node=
loop_pid=

cleanup() {
  status=$?
  trap - EXIT INT TERM
  if [ -n "$node" ]; then
    echo "Uncordoning ${node}"
    kubectl uncordon "$node" || true
  fi
  if [ -n "$loop_pid" ]; then
    touch "$STOP" || true
    kill "$loop_pid" 2>/dev/null || true
    wait "$loop_pid" 2>/dev/null || true
  fi
  if [ "$status" -ne 0 ] && [ -f "$OK" ]; then
    echo "curl successes=$(wc -l < "$OK" | tr -d ' ') failures=$(wc -l < "$FAIL" | tr -d ' ')" >&2
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

pod_table() {
  kubectl -n "$NS" get pods -l app.kubernetes.io/name=quote-api -o wide
}

running_pods() {
  kubectl -n "$NS" get pods -l app.kubernetes.io/name=quote-api \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}'
}

echo "Quote pods before the drain"
pod_table

nodes_cap=$(kubectl get nodes -l acme.io/capacity -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.labels.acme\.io/capacity}{"\n"}{end}')
pod_lines=$(running_pods)

ondemand_node=$(printf '%s\n' "$nodes_cap" | awk '$2 == "on-demand" { print $1; exit }')
ondemand_pod=$(printf '%s\n' "$pod_lines" | awk -v node="$ondemand_node" '$2 == node { print $1; exit }')
if [ -z "$ondemand_node" ] || [ -z "$ondemand_pod" ]; then
  echo "ERROR: expected a running quote pod on the on-demand node" >&2
  exit 1
fi

# Traefik is a single replica. Draining its node drops the ingress even though
# quote-api still has endpoints, so prefer another spot node.
ingress_node=$(kubectl -n kube-system get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' | awk '$1 ~ /^traefik-/ { print $2; exit }')

target=
target_pod=
fallback=
fallback_pod=
while read -r n cap; do
  [ -n "$n" ] || continue
  [ "$cap" = "spot" ] || continue
  count=$(printf '%s\n' "$pod_lines" | awk -v node="$n" '$2 == node { c++ } END { print c + 0 }')
  if [ "$count" -ne 1 ]; then
    continue
  fi
  pod=$(printf '%s\n' "$pod_lines" | awk -v node="$n" '$2 == node { print $1; exit }')
  if [ -z "$fallback" ]; then
    fallback=$n
    fallback_pod=$pod
  fi
  if [ "$n" != "$ingress_node" ]; then
    target=$n
    target_pod=$pod
    break
  fi
done <<EOF
$nodes_cap
EOF
if [ -z "$target" ]; then
  target=$fallback
  target_pod=$fallback_pod
fi

if [ -z "$target" ] || [ -z "$target_pod" ]; then
  echo "ERROR: need a spot node with exactly one quote pod so the PDB can allow the drain" >&2
  exit 1
fi

stay_pod=$(printf '%s\n' "$pod_lines" | awk -v node="$target" -v od="$ondemand_pod" '$2 != node && $1 != od { print $1; exit }')
stay_node=$(printf '%s\n' "$pod_lines" | awk -v pod="$stay_pod" '$1 == pod { print $2; exit }')
if [ -z "$stay_pod" ] || [ -z "$stay_node" ]; then
  echo "ERROR: expected the other spot node to keep one quote pod" >&2
  exit 1
fi

node=$target
echo "Draining ${target} (pod ${target_pod})"
echo "On-demand pod ${ondemand_pod} on ${ondemand_node} should stay"
echo "Spot pod ${stay_pod} on ${stay_node} should stay"

rm -f "$STOP"
: > "$OK"
: > "$FAIL"
(
  while [ ! -f "$STOP" ]; do
    if curl -fsS -o /dev/null --max-time 3 "$URL"; then
      echo ok >> "$OK"
    else
      echo fail >> "$FAIL"
    fi
    sleep 1
  done
) &
loop_pid=$!

kubectl drain "$target" \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --grace-period=15 \
  --timeout=180s

echo "Waiting for the replacement pod"
i=0
while [ "$i" -lt 45 ]; do
  if ! kubectl -n "$NS" get pod "$target_pod" >/dev/null 2>&1; then
    now=$(running_pods)
    running=$(printf '%s\n' "$now" | awk 'NF { c++ } END { print c + 0 }')
    on_target=$(printf '%s\n' "$now" | awk -v node="$target" '$2 == node { c++ } END { print c + 0 }')
    if [ "$running" -eq 3 ] && [ "$on_target" -eq 0 ]; then
      break
    fi
  fi
  i=$((i + 1))
  sleep 2
done

now=$(running_pods)
echo "Quote pods while ${target} is cordoned"
pod_table

running=$(printf '%s\n' "$now" | awk 'NF { c++ } END { print c + 0 }')
on_target=$(printf '%s\n' "$now" | awk -v node="$target" '$2 == node { c++ } END { print c + 0 }')
moved_to=$(printf '%s\n' "$now" | awk -v stay="$stay_pod" -v od="$ondemand_pod" '$1 != stay && $1 != od { print $2; exit }')
od_now=$(kubectl -n "$NS" get pod "$ondemand_pod" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
stay_now=$(kubectl -n "$NS" get pod "$stay_pod" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
if [ "$running" -ne 3 ] || [ "$on_target" -ne 0 ] || [ "$moved_to" != "$stay_node" ] || [ "$od_now" != "$ondemand_node" ] || [ "$stay_now" != "$stay_node" ]; then
  echo "ERROR: expected the drained pod to return on ${stay_node} and ${ondemand_pod} to stay on ${ondemand_node}" >&2
  echo "running=${running} on_drained=${on_target} moved_to=${moved_to:-missing} ondemand=${od_now:-missing} stayed=${stay_now:-missing}" >&2
  exit 1
fi
echo "Replacement is on ${stay_node}; on-demand pod did not move"

sleep 2
touch "$STOP"
sleep 2
kill "$loop_pid" 2>/dev/null || true
wait "$loop_pid" 2>/dev/null || true
loop_pid=

ok=$(wc -l < "$OK" | tr -d ' ')
fail=$(wc -l < "$FAIL" | tr -d ' ')
echo "curl successes=${ok} failures=${fail}"
if [ "$fail" -ne 0 ] || [ "$ok" -lt 5 ]; then
  echo "ERROR: quote endpoint did not stay available during the drain" >&2
  exit 1
fi

echo "Uncordoning ${target}"
kubectl uncordon "$target"
node=

echo "Restoring one quote pod per spot node"
extra=$(printf '%s\n' "$now" | awk -v stay="$stay_pod" -v od="$ondemand_pod" '$1 != stay && $1 != od { print $1; exit }')
kubectl -n "$NS" delete pod "$extra" --wait=true --timeout=60s

i=0
while [ "$i" -lt 45 ]; do
  now=$(running_pods)
  running=$(printf '%s\n' "$now" | awk 'NF { c++ } END { print c + 0 }')
  on_first=$(printf '%s\n' "$now" | awk -v node="$target" '$2 == node { c++ } END { print c + 0 }')
  on_second=$(printf '%s\n' "$now" | awk -v node="$stay_node" '$2 == node { c++ } END { print c + 0 }')
  od_now=$(kubectl -n "$NS" get pod "$ondemand_pod" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
  if [ "$running" -eq 3 ] && [ "$on_first" -eq 1 ] && [ "$on_second" -eq 1 ] && [ "$od_now" = "$ondemand_node" ]; then
    break
  fi
  i=$((i + 1))
  sleep 2
done

echo "Quote pods after uncordon"
pod_table
if [ "$running" -ne 3 ] || [ "$on_first" -ne 1 ] || [ "$on_second" -ne 1 ] || [ "$od_now" != "$ondemand_node" ]; then
  echo "ERROR: pods did not return to one per spot node" >&2
  exit 1
fi

echo "DRILL_OK"
