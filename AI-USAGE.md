# AI usage

I used two tools, and I kept the decisions.

ChatGPT turned my rough notes into prompts that matched the assignment, and it helped me revise the commit plan before I approved a stage. Cursor's agent drafted the harness, the quote service, the Helm chart, the scripts, and the docs. I read the diff, ran the check for that change, and committed it myself. One logical change at a time. Cursor is not a commit author, and `.cursor/` is not in the repo.

A change stayed only when a live check agreed with it: the unit tests, `terraform validate`, `troubleshoot/verify.sh`, or the matching script under `./scripts/`. A passing exit code was not enough when the printed result was wrong.

## How the prompts were made

Before the first implementation prompt, I wrote the working rules in my own words and asked ChatGPT to make them precise:

- Explain the work before changing code.
- Implement one git commit at a time.
- Suggest one commit message and wait for my approval.
- Do not commit, and do not add Cursor as a collaborator.
- Do not commit `.cursor/` files.
- Keep the code simple and the architecture small. This is a technical assessment.

I then asked Cursor for a commit plan that included Parts 4, 5, and 6. I reviewed that plan, used ChatGPT to tighten the next prompt, and approved the stage only after the plan matched the brief. Later prompts were short on purpose: implement the next approved commit, then stop.

## Where Cursor was wrong

### k6 summary fields

Cursor generated `scripts/60-loadtest.sh` to print latency and the failure rate from k6's `--summary-export`. The load test exited 0 and the k6 thresholds passed. The wrapper printed:

```
p95_ms=null
failed_rate=null
```

The test had run. The report had not. I opened `/tmp/k6-summary.json` and looked at `.metrics.http_req_duration` and `.metrics.http_req_failed`. k6 2.4.0 puts `p(95)` on the metric object, and the failure rate on `.value`. The generated queries used `.values["p(95)"]` and `.values.rate`, which are not in that file.

I changed the two lines in `scripts/60-loadtest.sh` to:

```sh
p95=$(jq -r '.metrics.http_req_duration["p(95)"]' /tmp/k6-summary.json)
failed=$(jq -r '.metrics.http_req_failed.value' /tmp/k6-summary.json)
```

The next run printed `p95_ms=142.88` and `failed_rate=0`. I reviewed that diff and committed the corrected script myself.

### An Argo CD value the chart does not have

The Argo CD install set `applicationSet.enabled=false` on chart 10.18.0. Helm accepted the flag and stored it. That chart has no `applicationSet.enabled` key, so the ApplicationSet controller is still installed. Accepting a `--set` is not the same as the chart honoring it.

I removed that `--set` from `scripts/20-deploy.sh`. `dex.enabled=false` and `notifications.enabled=false` are real keys in 10.18.0, and those stayed.

## What I kept responsibility for

I treated both tools' output as a proposal. I approved the plan, the diff, and the commit message. Architecture, security context, placement, and what to leave out stayed with me. Verification was a command I could re-run, not a summary in the chat.
