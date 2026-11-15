# Ops answers

## 1. EKS 1.33 to 1.35 with no downtime

EKS moves the control plane one minor at a time: 1.33 → 1.34, then 1.34 → 1.35. Same sequence twice.

Run upgrade insights and fix calls to APIs the next minor removes. If vpc-cni, EBS CSI, or EFS CSI does not support that minor, upgrade it to a build that supports both versions first. Upgrade the control plane. It stays highly available and pods stay put. Then set kube-proxy, CoreDNS, vpc-cni, and both CSI drivers to the EKS build for that minor. CoreDNS keeps a PodDisruptionBudget. The CNI and kube-proxy DaemonSets roll one node at a time. Roll workers to the same minor: managed node groups with a surge, Karpenter by drift, one pool at a time, honoring disruption budgets. GPU nodes last. A 1.35 kubelet needs Amazon Linux 2023 or Bottlerocket.

Three risks. On 1.35, `failCgroupV1` defaults to true, so an Amazon Linux 2 node never becomes Ready and the roll can drain the last healthy node. Canary one node first. An old vpc-cni or kube-proxy against the new API server leaves pods without addresses or breaks Services, and an old CSI driver fails mounts during the drain. Pin each addon to the build AWS lists for the control plane you are on. Rolling both spot nodes at once, or ignoring `maxUnavailable: 1`, drops the last replica. EBS volumes stay in one zone, so a replacement in another zone leaves those pods Pending.

## 2. Spot reclaims paging on KubeNodeUnreachable

The alert means the kubelet stopped heartbeating. A reclaim does that on purpose. Karpenter drains inside the two-minute warning, then deletes the Node.

Page only when a Node is still NotReady after 15 minutes. A finished reclaim is gone before that. Skip the page when Karpenter has marked the node disrupted. On-demand and GPU nodes keep a short window. A spot node still NotReady after 15 minutes did not finish the reclaim, so it pages, as does a crash with no interruption notice. The fast signal is the workload: a Deployment short of available replicas, or pods Pending with nowhere to run. Several nodes NotReady in the same few minutes is a page even on spot. That is a zone or a fleet, not one reclaim.

## 3. Mobile LCP at 5s, suspect HTML is not cached

Name the LCP element on a mobile run and split time to first byte from the time to fetch that element. A slow image on a fast document is an asset problem. Caching the HTML will not move it.

Request the document twice with a phone User-Agent. Read `cf-cache-status`, `age`, `cache-control`, `set-cookie`, and `vary`. HIT on the second request means the edge stored it. DYNAMIC or BYPASS means a rule or the origin refused. MISS both times means the cache key changed.

In the zone ruleset `http_request_cache_settings`, the later matching rule wins. A cookie or HTML bypass, or a static-asset rule that never matches the document, leaves HTML uncached. Cloudflare caches HTML only when a rule says so. Origin `private`, `no-store`, or `max-age=0`, plus `Set-Cookie` or `Vary: Cookie`, blocks one shared copy. If the rule overrides the origin TTL and the second request is HIT, measure LCP again before touching the page. An edge HIT with a browser TTL of zero still makes every phone download the document.

## 4. Secrets on several production EKS clusters

Sealed Secrets encrypts a value to one cluster's key and stores the ciphertext in git. Each extra cluster needs its own seal. Lose the key and that ciphertext cannot be opened.

External Secrets Operator reads AWS Secrets Manager with Pod Identity and writes a Kubernetes Secret in each cluster. One AWS write rotates the value. Each cluster may read only its own secrets, and EKS encryption at rest covers the etcd copy.

I would use External Secrets. The clusters share one source of truth, and a rotation is one write.
