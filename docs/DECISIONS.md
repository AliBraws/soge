# Architecture Decision Records

Each record: context → decision → consequences (what was given up).

## ADR-001 — Product: FX quote & execution
**Context.** "A small production-ready application" for a bank. URL shorteners are judged too common.
**Decision.** Request-for-quote flow on ECB reference rates: price → lock (15 s) → execute → history.
**Consequences.** Realistic SRE problems in a small scope: a read-heavy hot path, money-moving writes that must happen exactly once, an external dependency that can fail. Prices are indicative (ECB + bounded random walk), so this is not a trading system.

## ADR-002 — ECS Fargate on Graviton, not EKS, not Lambda
**Decision.** One ECS Fargate service, ARM64, multi-arch image.
**Consequences.**
- No control plane to pay for or patch; per-task isolation; about 20% cheaper on Graviton.
- Not chosen: EKS, whose value (operators, GitOps controllers, many teams) does not apply to one service. The image is distroless, multi-arch, configured by environment only, with liveness separate from readiness, so it can land on an EKS + Argo CD platform unchanged.
- Not chosen: Lambda for the API, because of cold starts on the money path and DB connection fan-out.

## ADR-003 — UI embedded in the API image
**Decision.** The static UI is compiled into the Go binary (`go:embed`) and served on the same TLS 1.3 listener; CloudFront caches it.
**Consequences.**
- One versioned artifact: UI and API are always compatible, and a rollback rolls both back.
- Fully containerized as required, and no second service or bucket to secure.
- Trade-off: a UI change ships a new image. If the UI grows (SPA framework, separate team), move it to S3 + CloudFront (OAC).

## ADR-004 — API Gateway REST + Lambda authorizer
**Decision.** Regional REST API, custom domain only, `SecurityPolicy_TLS13_1_3_2025_09` in STRICT mode, REQUEST authorizer, VPC link v2 straight to the internal ALB.
**Consequences.**
- HTTP APIs are cheaper but offer no WAF and no TLS 1.3-only policy.
- VPC link v2 removes the NLB that REST APIs used to need.
- The integration timeout is 29 s, which is irrelevant here.

## ADR-005 — Tokens: short-lived, renewed, rotating key; origin verification
**Decision.**
- HS256 JWT with 5 min TTL; `kid` = Secrets Manager VersionId.
- The client renews at 80% of the TTL, presenting its current token (same subject).
- The key is rotated every 4 h by a rotation Lambda; verifiers accept current and previous versions.
- CloudFront adds `X-Origin-Verify` (a rotating secret), checked by the authorizer and stripped before the backend, so the regional API cannot be called while bypassing CloudFront and its WAF.

**Consequences.** Revocation is bounded by the TTL. In production the bank's IdP issues asymmetric tokens (JWKS) and only the verifier changes.

## ADR-006 — A VPC with no route to the internet; Lambdas outside it
**Decision.** Dedicated VPC (not the default VPC), no IGW, no NAT. The containers use VPC endpoints. The Lambdas (authorizer, issuer, rotators, rates_sync) run outside the VPC.
**Consequences.**
- A compromised container cannot call out.
- No NAT (about $100/month for 3 AZs), no internet egress to filter.
- No `ec2:*NetworkInterface*` permissions on `"*"` for the Lambdas.
- Each Lambda's IAM role is restricted to its own secret or object.

## ADR-007 — KMS customer-managed keys, not BYOK
**Decision.**
- One customer-managed key per data domain, with AWS-generated material.
- Automatic rotation every 90 days.
- Explicit key policies.

**Why not BYOK.**
- `aws_kms_external_key` stores the imported material in the Terraform state, which would break ADR-009.
- Imported material cannot rotate automatically: on-demand rotation means re-importing from the HSM.
- Durability of the imported material becomes our responsibility.

**Consequences.** If the bank requires BYOK, its security team creates the keys from its HSM and only their ARNs are passed to Terraform.

## ADR-008 — Signed quotes, idempotent append-only executions
**Decision.**
- Quotes are HMAC-signed tokens, so no DB is touched on the read path.
- Executions carry an `Idempotency-Key`. `UNIQUE(owner, idem_key)` replays the original deal (422 if the payload differs), and `UNIQUE(quote_id)` allows only one execution per quote.
- The DB role has `SELECT, INSERT` only.

**Consequences.** Read capacity scales linearly with tasks. A retry during a failover is always safe. Corrections are compensating entries, never updates.

## ADR-009 — No secret in Terraform state or plan
**Decision.**
- Terraform ≥ 1.11: `ephemeral "random_password"` → `secret_string_wo` (only `_wo_version` stored), followed by immediate rotation.
- Aurora admin password: `manage_master_user_password`. The app uses IAM DB auth.
- State: S3 + KMS, versioned, TLS-only, native locking (`use_lockfile`).

**Consequences.** Reading the state never reveals a secret. Write-only values cannot be diffed, so changes go through the version counter.

## ADR-010 — Aurora PostgreSQL 18 Serverless v2, 3 AZ
**Decision.**
- Writer + 1 reader in two AZs (automatic failover), storage replicated over 3 AZs; 0.5–2 ACU per instance (cost ceiling). A third instance is one variable away (`aurora_instance_count = 3`).
- Isolated subnets, TLS 1.3 minimum, IAM auth, PITR 14 days.
- The deal history is read from the reader endpoint.

**Consequences.** Failover takes about 30 s. No capacity planning. The cost floor is about 1.5 ACU.

## ADR-011 — CI/CD trust chain
**Decision.**
- GitHub OIDC with three roles: plan (read-only), push (ECR only, main), apply (protected environment, admin within a boundary).
- Trust is bound to the **immutable subject** (`repo:<owner>@<owner_id>/<repo>@<repo_id>:…`, GitHub default for repositories created after 2026-07-15): deleting and recreating a repository with the same name cannot inherit the AWS trust.
- Third-party actions pinned by commit SHA.
- Multi-arch build without emulation, SBOM + SLSA provenance, Trivy gates (IaC, dependencies, image), cosign keyless signature verified before deploying.
- Deployment by digest; migrations before rollout.

**Consequences.** No long-lived credential exists. Every running task is traceable to a commit. Next step: verify signatures at runtime, not only in the pipeline.

## ADR-012 — Mandatory tags
**Decision.**
- Five tags on every resource: `Project`, `Environment`, `Owner`, `ManagedBy`, `Repository`.
- Applied via provider `default_tags`, propagated to ECS tasks.
- Asserted by a Terraform `check` and by tflint `aws_resource_missing_tags` in CI.

**Consequences.** Cost allocation, ownership and traceability to the source repository for every resource. Next step: an AWS Organizations tag policy with enforcement.

## ADR-013 — API Gateway → ALB: TLS 1.3 offered, restricted TLS 1.2 accepted
**Context.** With the ALB listener on `ELBSecurityPolicy-TLS13-1-3-PQ-2025-09` (TLS 1.3 only), every request failed with HTTP 500. `test-invoke-method` logged `Execution failed due to configuration error: Received fatal alert: protocol_version`, while the 3 targets were healthy and the authorizer allowed the call. The `SecurityPolicy_TLS13_1_3_2025_09` policy on API Gateway applies to clients calling the API, not to its own connection to the integration.
**Evidence.** A/B test changing one parameter only (listener policy): TLS 1.3-only → `protocol_version`, HTTP 500; `ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09` → integration status 200 (25 ms) and `https://soge.labs.athoria.fr/` HTTP/2 200.
**Decision.** Listener policy `ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09`: TLS 1.3 preferred, TLS 1.2 limited to ECDHE + AES-GCM, hybrid post-quantum key exchange.
**Consequences.**
- Browser → CloudFront → API Gateway stays TLS 1.3 only; ALB → tasks and tasks → Aurora stay TLS 1.3.
- The one hop on TLS 1.2 is private (VPC link v2 over PrivateLink, SG-to-SG, no internet route). TLS 1.2 is not deprecated (RFC 8996 deprecates 1.0 and 1.1 only).
- Revisit when API Gateway integrations negotiate TLS 1.3: switch back to `TLS13-1-3-PQ` and re-run the same `test-invoke-method` check.
