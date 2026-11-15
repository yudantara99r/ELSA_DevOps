# AI usage

Cursor's agent drafted the harness, the quote service, the Helm chart, the scripts, and the docs. I kept one commit at a time and committed it myself. A change stayed only after a live check agreed with it: the unit tests, `terraform validate`, `troubleshoot/verify.sh`, or the matching script under `./scripts/`.

## Prompts

These are real prompts from the session.

1. Remake the plan so Parts 4, 5, and 6 are all included, then implement the first commit.
2. Do the cgroupfs change and implement the second commit (the quote service and its image).
3. Go ahead with the spot reclaim drill, then continue one commit at a time.

## Where the output was wrong

The first k6 wrapper read the summary export as `.metrics.http_req_duration.values["p(95)"]` and `.metrics.http_req_failed.values.rate`. k6 2.4.0 puts `p(95)` directly on the metric, and the failure rate on `.value`. The run exited 0 and the console showed the thresholds passing, while `jq` printed `null`. I opened `/tmp/k6-summary.json` and pointed `scripts/60-loadtest.sh` at `.metrics.http_req_duration["p(95)"]` and `.metrics.http_req_failed.value`. The next run printed `p95_ms=142.88` and `failed_rate=0`.

The Argo CD install set `applicationSet.enabled=false`. Chart 10.18.0 has no such key. Helm stored the flag, and the ApplicationSet controller still ships with that chart. I removed the `--set`. `dex.enabled` and `notifications.enabled` are real keys and stayed.
