# Load & scaling

## Method

`loadtest/k6.js`, run from the `load-test` workflow, or from a laptop: `k6 run -e TARGET=https://soge.<domain> loadtest/k6.js` (one laptop = one IP: keep `PEAK_RPS` ≤ 4) (`make load-local` against the local stack).

- **Open model** (`ramping-arrival-rate`): the arrival rate does not drop when the system slows down. A closed model (fixed number of VUs) hides saturation.
- **Realistic mix:** 90% quotes, 8% blotter reads, 2% executions. Each execution is **replayed with the same Idempotency-Key** and must return the same deal.
- **Profile (per runner):** warm-up → ramp to `PEAK_RPS` → sustain → spike ×2 → recovery (16 min).
- **Thresholds = SLOs:** error rate < 0.1%, quote p95 < 300 ms, p99 < 800 ms, execution p95 < 500 ms. A breach fails the job.

**Cost guardrails stay on during the test** (shared AWS account: the bill must stay bounded): WAF blocks any IP above 2 000 requests / 5 min, API Gateway caps the whole API at 50 req/s (burst 100), ECS at 6 tasks, Aurora at 2 ACU per instance, Lambda by reserved concurrency, and a daily AWS Budget e-mails at 80% / 100% of 10 USD. The WAF limit is per source IP, so the load is **distributed**: the workflow runs `runners` parallel k6 jobs (default 4, one GitHub runner = one IP), each at `PEAK_RPS=4` (spike 8). Total: ~16 req/s sustained, ~32 req/s at the spike, under the API Gateway ceiling of 50 req/s, and above the scale-out point (3 tasks × 300 req/min ≈ 15 req/s). A single source pushing harder is blocked with 403 at the edge, and the whole API beyond 50 req/s gets 429: both are the intended protective behaviour, not failures of the service.

## What to watch (dashboard `soge-prod`)

| Panel | Expected behaviour |
|---|---|
| ECS running tasks | 3 → scale-out within ~1–2 min of the ramp (target tracking on CPU 60% **and** 300 req/task/min), up to 6 tasks, back to 3 after ~5 min of calm (slow scale-in) |
| Latency p50/p95/p99 | flat during the ramp; short p99 bump at each scale-out step |
| Aurora ACU / connections | ACU grows with executions only (quotes never hit the DB); connections bounded by tasks × 10 |
| 5xx | ~0. Any 5xx during a scale event is an SLO incident |

## Results

> Fill in after the run (screenshots in `docs/img/`). Numbers below are placeholders, not measurements.

| Phase | RPS | p95 quote | p99 quote | errors | tasks (api) | Aurora ACU |
|---|---|---|---|---|---|---|
| warm-up | — | — | — | — | — | — |
| sustain | — | — | — | — | — | — |
| spike ×2 | — | — | — | — | — | — |

## Scaling headroom & next limits

1. **Read path:** linear in the number of tasks (no shared state). `max_tasks = 6` is a cost guard, not a technical limit.
2. **Write path:** one Aurora writer. Serverless v2 scales vertically up to `aurora_max_acu`. Next steps: RDS Proxy, then sharding by client or a queue in front of execution if needed.
3. **Edge:** CloudFront caches static assets. API Gateway stage throttling (50 req/s, burst 100) and the WAF per-IP rate rule protect the backend and the bill; both are variables, raised deliberately, never by traffic.
