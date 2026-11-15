# Troubleshooting

`troubleshoot/broken-app.yaml` was applied as provided. `troubleshoot/prepare.sh` had already labeled two nodes `acme.io/capacity=spot`, one `acme.io/capacity=on-demand`, and `k3d-elsa-agent-3` as `acme.io/node-type=gpu` with taint `nvidia.com/gpu=true:NoSchedule`. The fixes are in `troubleshoot/fixed-app.yaml`. The provided files were not edited, the default-deny policy was not deleted, and no node label or taint was removed.

Several faults stack on the same Pod, so the scheduler stops at the first one. The image, probe, and volume faults are visible in the Pod spec before a container is created.

## 1. Web Pod requests 16Gi

**Symptom.** `web-6d699f8fcd-mmhwr` stays `Pending`. The scheduler event is:

```text
0/5 nodes are available: 1 node(s) had untolerated taint(s), 4 Insufficient memory.
```

**Commands.**

```bash
kubectl apply -f troubleshoot/broken-app.yaml
kubectl -n troubleshoot get pods -o wide
kubectl -n troubleshoot describe pod -l app=web
kubectl get nodes -o custom-columns=NAME:.metadata.name,ALLOC:.status.allocatable.memory
```

**Root cause.** The container requests and limits `memory: 16Gi`. Every node reports `16252600Ki` allocatable, about 15.5Gi, so four nodes reject the Pod for memory. The fifth is the GPU node. Its taint is expected: this Deployment is not the GPU workload and must not tolerate `nvidia.com/gpu`.

**Fix.** Request `64Mi` and limit `128Mi`. CPU stays `100m` / `500m`.

## 2. Image `nginx:1.25.99` does not exist

**Symptom.** The Pending Pod's container image is `nginx:1.25.99`. It never reaches `ImagePullBackOff` because issue 1 keeps it unschedulable.

**Commands.**

```bash
kubectl -n troubleshoot describe pod -l app=web
docker pull nginx:1.25.99
```

`docker pull` returns:

```text
docker.io/library/nginx:1.25.99: not found
```

The `1.25` tags on Docker Hub stop at `1.25.5`.

**Root cause.** `1.25.99` is not a published nginx tag.

**Fix.** `image: nginx:1.25.5`.

## 3. Probes use port 8080

**Symptom.** The same `describe` shows the container port and the probes disagree:

```text
Port:      80/TCP
Liveness:  http-get http://:8080/ delay=5s
Readiness: http-get http://:8080/ delay=3s
```

**Commands.** `kubectl -n troubleshoot describe pod -l app=web`

**Root cause.** nginx listens on 80. A probe to 8080 fails as soon as the container starts, so the Pod never becomes Ready.

**Fix.** Both probes use `port: 80` and `path: /`.

## 4. Volume references ConfigMap `web-conf`

**Symptom.** The Pod volume is not optional and names a ConfigMap that is not in the namespace:

```text
Volumes:
  html:
    Type: ConfigMap
    Name: web-conf
```

`kubectl -n troubleshoot get configmap` lists `web-config` only.

**Commands.**

```bash
kubectl -n troubleshoot describe pod -l app=web
kubectl -n troubleshoot get configmap
```

**Root cause.** The volume configMap name is `web-conf`. The manifest creates `web-config`, whose `index.html` contains `TROUBLESHOOT-OK`. Once the Pod is scheduled and the image is pulled, kubelet reports `CreateContainerConfigError`.

**Fix.** The volume references `web-config`. The mount path stays `/usr/share/nginx/html`.

## 5. Service selector is `app=webapp`

**Symptom.** `web-svc` has a ClusterIP and no endpoints. Two web Pods from the previous ReplicaSet were still Running with label `app=web`. The Endpoints object has no `subsets`.

**Commands.**

```bash
kubectl -n troubleshoot get pods -o wide
kubectl -n troubleshoot get endpoints web-svc -o yaml
kubectl -n troubleshoot get svc web-svc -o yaml
```

The Service spec is `selector.app: webapp`.

**Root cause.** The Pod label and the Deployment selector are `app: web`. The Service selects `app: webapp`, so ready Pods are never attached.

**Fix.** `selector: app: web`.

## 6. Service `targetPort` is 8080

**Symptom.** The same Service yaml sets `port: 80` and `targetPort: 8080`. The container port in the Pod spec is 80.

**Commands.** `kubectl -n troubleshoot get svc web-svc -o yaml`

**Root cause.** Even with the selector corrected, kube-proxy would send traffic to 8080 and nginx would not answer. `verify.sh` treats an empty endpoint list and a black-holed port as the same failure.

**Fix.** `targetPort: 80`.

## 7. Inference selector looks up `node-type=gpu`

**Symptom.** `ai-inference-75ffc89584-wfxmf` stays `Pending`. The scheduler event is:

```text
0/5 nodes are available: 1 node(s) had untolerated taint(s), 4 node(s) didn't match Pod's node affinity/selector.
```

`describe` shows `Node-Selectors: node-type=gpu`.

**Commands.**

```bash
kubectl -n troubleshoot describe pod -l app=ai-inference
kubectl get nodes -L acme.io/node-type -L acme.io/capacity
```

`k3d-elsa-agent-3` is the only node with `acme.io/node-type=gpu`. No node has a label named `node-type`.

**Root cause.** The selector key does not match the label `prepare.sh` set.

**Fix.** `nodeSelector: acme.io/node-type: gpu`.

## 8. Inference Pod has no GPU toleration

**Symptom.** The same event counts one node as an untolerated taint. That node is `k3d-elsa-agent-3`. The Pod's tolerations are only the default `not-ready` and `unreachable` entries. There is no `nvidia.com/gpu` toleration.

**Commands.**

```bash
kubectl -n troubleshoot describe pod -l app=ai-inference
kubectl get node k3d-elsa-agent-3 -o jsonpath='{.spec.taints}'
```

The taint is `nvidia.com/gpu=true:NoSchedule`.

**Root cause.** Correcting the label key is not enough. The GPU node would still reject the Pod. Removing the taint is not a fix; `verify.sh` checks that the key is still present.

**Fix.**

```yaml
tolerations:
  - key: nvidia.com/gpu
    operator: Equal
    value: "true"
    effect: NoSchedule
```

After both changes, `verify.sh` finds the inference Pod on `k3d-elsa-agent-3`.

## 9. default-deny has no allow rules

**Symptom.** With the workloads healthy and only `default-deny` in the namespace, `smoke-test` exits on the first curl. The log is:

```text
curl: (7) Failed to connect to web-svc.troubleshoot.svc.cluster.local port 80 after 2 ms: Couldn't connect to server
```

The name resolved. The connection was rejected in about 2ms, which is the policy drop, not an application timeout. Deleting `default-deny` would also make this pass, and `verify.sh` fails that approach on purpose.

**Commands.**

```bash
kubectl -n troubleshoot delete networkpolicy web-allow-smoke smoke-client-allow
kubectl -n troubleshoot delete job smoke-test --ignore-not-found
kubectl apply -f troubleshoot/smoke-job.yaml
kubectl -n troubleshoot logs job/smoke-test
kubectl get networkpolicy default-deny -n troubleshoot
```

**Root cause.** `default-deny` selects every Pod and sets both `Ingress` and `Egress`. The smoke Job (`app=smoke-client`, image `curlimages/curl:8.7.1`) must reach CoreDNS and the web Pods. The web Pods must accept that client on port 80. Nothing else needs a path: nginx serves the mounted page, and the inference container only sleeps.

**Fix.** Two policies, left alongside `default-deny`:

- `web-allow-smoke` allows ingress from `app=smoke-client` to `app=web` on TCP 80.
- `smoke-client-allow` allows egress from `app=smoke-client` to `kube-system` Pods labeled `k8s-app=kube-dns` on UDP and TCP 53, and to `app=web` on TCP 80.

On this k3s build the lookup succeeded under default-deny, and the observed failure was the drop to port 80. The DNS rule is still there so name resolution does not depend on that gap.

## Check

`scripts/30-troubleshoot.sh` applies the broken file, then `fixed-app.yaml`, then `troubleshoot/verify.sh`. The verifier prints `PASS`: default-deny still exists, labels and the GPU taint are unchanged, both Deployments roll out, the inference Pod is on the GPU node, `web-svc` has endpoints, and the smoke Job body contains `TROUBLESHOOT-OK`.
