# Load test

k6 in the toolbox calls `http://host.docker.internal:8080/api/quote`. Each request burns about 100ms of CPU.

Measured on this machine, three replicas, zero failures:

| Rate | p95 | Achieved |
| --- | --- | --- |
| 2 rps for 20s | 126ms | 2.0 rps |
| 30 rps for 20s | 171ms | 29.9 rps |
| 60 rps for 20s | 207ms | 59.6 rps |
| 120 rps for 20s | 259ms (max 473ms) | 119 rps |

`scripts/60-loadtest.sh` holds 12 rps. Two full runs finished at p95 127ms and 143ms, both with `http_req_failed` at 0. The thresholds are `rate==0` and `p(95)<200`: above those two runs and the 30 rps probe, and below the 60 rps result where the tail left the baseline.

The highest rate that stayed near the baseline was about **60 rps** on three replicas. At 120 rps the service still returned 200s, but the slowest requests reached 473ms and k6 needed more in-flight VUs. The limit is the 100ms CPU burn in the app. The ingress did not drop connections. On this k3d cluster the 500m CPU limit did not throttle the pods, so three processes used whole cores. In production I would scale replicas first. The HPA already targets 70% of the 100m request, and the run above moved it from 3 to 6 (CPU reported 242% before the extra pods). New pods stayed on spot and on-demand, three and three. I would add nodes only after the replica ceiling is the thing in the way.

`QuoteApiErrors` pages when `/api/quote` has a non-zero error ratio for 10 minutes. Nothing in these runs returned a non-200, including 120 rps, so a ratio that stays above zero is not this workload.

The Grafana dashboard is `monitoring/quote-api-dashboard.json`. `monitoring/quote-api-during-load.png` was taken while this scenario was running: request rate near 12/s, replicas moving to 6, and CPU climbing.
