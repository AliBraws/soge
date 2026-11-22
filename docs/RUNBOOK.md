# Runbook

## SLOs

| SLI | Objective (30 days) | Measured at | Alarm |
|---|---|---|---|
| Availability: share of `/x/*` requests not 5xx | 99.9% (43 min error budget) | ALB + API Gateway | `soge-alb-5xx-ratio`, `soge-apigw-pub-5xx`, composite `soge-slo-breach` |
| Latency: quote p95 | < 300 ms at the ALB, < 500 ms at API Gateway | ALB `TargetResponseTime` p95 | `soge-alb-p95` |
| Correctness: duplicate executions | 0 | DB constraint + k6 replay check | — (by construction) |
| Freshness: age of the rates snapshot | < 26 h on business days | EMF `RatesFetchFailures` | `soge-rates-fetch-failures` |

Error-budget policy: if more than 50% of the budget is burnt, feature deploys freeze and only reliability fixes ship.

## Failure modes

| Symptom | Likely cause | Check | Action |
|---|---|---|---|
| 401 on every call from the public URL | origin-verify rotation half-done | `aws secretsmanager describe-secret` (stages), CloudFront origin header | re-run rotation: `aws secretsmanager rotate-secret --secret-id <origin>` |
| 401 after ~5 min for one user | token renewal blocked (clock skew, blocked /x/s) | authorizer Lambda logs (`/soge/prod/fn-authorizer`) | the client retries `/x/s`; check WAF sampled requests |
| 503 + `Retry-After` on `/x/d` only, quotes OK | Aurora failover / writer unavailable | RDS events, `DatabaseConnections` | none: the client retries with the same key. If > 2 min, check the writer |
| `rates: ecb:<old date>` in the UI | `rates_sync` failing (ECB unreachable, format change) | `/soge/prod/fn-rates_sync` logs, Lambda errors alarm | fix the cause. The service keeps quoting on the last snapshot |
| Deploy rolled back automatically | new revision broke health checks or SLO alarms | ECS service events, alarm history | inspect the failed task logs; the previous revision is serving |
| 403 from the edge | WAF rule (managed rules, rate limit) | WAF logs `aws-waf-logs-soge-edge` (us-east-1) | adjust the rule or the limit |
| Tasks all in one AZ after an incident | AZ just recovered | ECS service events | none: AZ rebalancing redistributes automatically |

## Chaos experiment (not automated in this repository)

A manual AWS FIS experiment validates the claims above. Run it **while k6 is running** at sustained load:

1. `aws:network:disrupt-connectivity` on the app subnet of one AZ for 5 minutes.
2. At the same time, `aws:rds:failover-db-cluster` on the Aurora cluster.
3. Stop condition: the composite alarm `soge-slo-breach`.

Expected results:
- the tasks of the lost AZ are replaced in the other two, and target tracking adds capacity;
- quotes are not interrupted;
- executions show a short burst of 503 + Retry-After, absorbed by client retries, with zero duplicates;
- AZ rebalancing after recovery.

## Rotation drills

```bash
aws secretsmanager rotate-secret --secret-id <jwt-secret-arn>     # sessions unaffected (current+previous accepted)
aws secretsmanager rotate-secret --secret-id <origin-secret-arn>  # CloudFront updated in setSecret, pending accepted
```

## Rollback

- Application: re-run the `deploy` workflow with the previous image digests (images are immutable, last 30 kept).
- Infrastructure: revert the commit, `infra-plan` → review → apply.
- Data: Aurora PITR (14 days) to a new cluster, then swap the endpoint (never in place).

## Stop / start (cost control between demos)

| Action | How | Time | What is left running |
|---|---|---|---|
| **Pause** | Actions → `power` → `off` → approve `prod` | ~5 min | VPC interface endpoints, ALB, WAF, KMS keys, secrets, logs: **≈ 4–5 USD/day** (estimate, eu-west-3 list prices) |
| **Resume** | Actions → `power` → `on` → approve `prod` | ~10 min (Aurora start) | everything; the job ends with the same smoke test as the deployment |
| **Destroy** | see *Tear down* below | ~20 min | nothing billed except S3 state and ECR images (cents) |
| **Rebuild after destroy** | Actions → `ci` → Run workflow on `main` → approve `prod` | ~25 min | full stack, same URL |

`power off` mutes alarm actions first (no alert storm), pins autoscaling to 0, scales the service to 0, then stops Aurora. `power on` does the reverse and re-enables alarms only after the smoke test passes. Terraform stays the source of truth: the next deployment re-applies `min_tasks`/`max_tasks`. **Resume before deploying**: a deployment against a stopped Aurora cluster fails. AWS restarts a stopped Aurora cluster after 7 days on its own; the daily budget alert covers that case.

Load tests never keep running: the profile lasts 16 min and the job is killed at 25 min (`timeout-minutes`). Stop one early with `gh run cancel <run-id>`.

## Tear down

1. **Platform**: Actions → `destroy` → Run workflow on `main`, type `soge`, approve `prod` (~15–20 min: Aurora, CloudFront).
2. **Bootstrap** (temporary admin session, CloudShell): the pipeline cannot delete the roles it runs with, and the state bucket holds its own state.
   ```bash
   cd infra/bootstrap
   rm backend.tf && terraform init -migrate-state -force-copy   # state back to local
   terraform apply -var allow_destroy=true                     # records force_destroy before deleting
   terraform destroy -var allow_destroy=true
   ```
KMS keys enter a 30-day pending deletion (aliases are freed immediately); secrets use a 7-day recovery window with prefixed names, so a new deployment does not collide.

## Incidents during delivery (blameless log)

| # | Symptom | Root cause (evidence) | Fix | Prevention |
|---|---|---|---|---|
| 1 | CI `AssumeRoleWithWebIdentity` denied | Repo created after July 2026: GitHub OIDC `sub` uses immutable IDs (`repo:owner@id/repo@id:…`), seen in CloudTrail | trust policy built from `github_sub_prefix` | variable validated by regex in bootstrap |
| 2 | `cosign verify` 401 | deploy job not logged in to ECR | ECR login before verification | — |
| 3 | Migration task `CannotPullContainerError` | no NAT: ECR layers come from S3 through the gateway endpoint, whose policy did not allow the AWS-owned layer bucket | endpoint policy scoped to `prod-<region>-starport-layer-bucket/*` | documented in `endpoints.tf` |
| 4 | Phase-2 apply errors | slow start + least-outstanding-requests incompatible; API Gateway account-level CloudWatch role (shared account); CloudFront refuses to strip `x-amzn-requestid`; `MAX` in metric math | each setting removed or rewritten | plan reviewed on PR before merge |
| 5 | Public URL HTTP 500 `DEFAULT_5XX` | `test-invoke-method`: `Received fatal alert: protocol_version` with TLS 1.3-only ALB listener; targets healthy, authorizer Allow | listener `ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09`, proven by A/B (one parameter changed: 500 → 200) | ADR-013; smoke test waits for the edge and fails the deploy |
