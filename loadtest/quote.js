import http from "k6/http";
import { check } from "k6";

// This scenario measured p95 127ms and 143ms, both with 0 failures.
// Probes on 3 replicas, also 0 failures: 2 rps p95 126ms, 30 rps p95 171ms,
// 60 rps p95 207ms, 120 rps p95 259ms.
// p95<200 is above this scenario and the 30 rps probe, and below the 60 rps result.
const url = __ENV.BASE_URL;

export const options = {
  scenarios: {
    quote: {
      executor: "ramping-arrival-rate",
      startRate: 2,
      timeUnit: "1s",
      preAllocatedVUs: 30,
      maxVUs: 60,
      stages: [
        { target: 2, duration: "20s" },
        { target: 12, duration: "20s" },
        { target: 12, duration: "90s" },
        { target: 2, duration: "15s" },
      ],
    },
  },
  thresholds: {
    http_req_failed: ["rate==0"],
    http_req_duration: ["p(95)<200"],
    checks: ["rate==1"],
  },
};

export default function () {
  const response = http.get(url);
  check(response, {
    "status is 200": (res) => res.status === 200,
    "body has a quote": (res) => res.body && res.body.indexOf("quote") !== -1,
  });
}
