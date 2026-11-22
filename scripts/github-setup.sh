#!/usr/bin/env bash
# Configures the GitHub repository. Runs BEFORE the bootstrap and creates no
# commit: every AWS name is deterministic (roles, state bucket, ECR derive from
# the account ID).
#
# No credential is stored anywhere: CI authenticates to AWS with OIDC.
# The repository is public, so its logs are public too. Identifying values
# (account ID, alarm e-mail, hosted zone ID) are therefore stored as Actions
# *secrets*: GitHub masks them in every log line. They are identifiers, not
# credentials: leaking one grants nothing.
#   REPO=<owner>/soge ./scripts/github-setup.sh        (values are prompted, never echoed or kept in history)
set -euo pipefail
: "${REPO:?set REPO=<owner>/<repo>}"

ask() { local v; read -r -s -p "$1: " v; echo >&2; printf '%s' "$v"; }
ACCOUNT_ID="${ACCOUNT_ID:-$(ask 'AWS account ID (12 digits)')}"
[[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || { echo "invalid account ID"; exit 1; }
ZONE_ID="${HOSTED_ZONE_ID:-$(ask 'Route 53 hosted zone ID (Z...)')}"
[[ "$ZONE_ID" =~ ^Z[A-Z0-9]+$ ]] || { echo "invalid hosted zone ID"; exit 1; }
EMAIL="${ALARM_EMAIL:-$(ask 'E-mail for alarms (kept secret)')}"

echo "Actions secrets on $REPO (masked in logs):"
printf '%s' "$ACCOUNT_ID" | gh secret set AWS_ACCOUNT_ID --repo "$REPO" && echo "  AWS_ACCOUNT_ID"
printf '%s' "$ZONE_ID"    | gh secret set HOSTED_ZONE_ID --repo "$REPO" && echo "  HOSTED_ZONE_ID"
printf '%s' "$EMAIL"      | gh secret set ALARM_EMAIL    --repo "$REPO" && echo "  ALARM_EMAIL"

echo "Actions variables (public by nature):"
gh variable set OWNER          --repo "$REPO" --body "$(gh api user --jq .login)" && echo "  OWNER (Owner tag = your GitHub login)"
gh variable set DEPLOY_ENABLED --repo "$REPO" --body false && echo "  DEPLOY_ENABLED=false (true once infra/platform is committed)"
for v in AWS_PLAN_ROLE_ARN AWS_PUSH_ROLE_ARN AWS_APPLY_ROLE_ARN STATE_BUCKET ECR_REPOSITORY ALARM_EMAIL HOSTED_ZONE_ID; do
  gh variable delete "$v" --repo "$REPO" >/dev/null 2>&1 || true   # values from an older setup
done

# Protected "prod" environment: you approve every deployment; only main deploys.
ME=$(gh api user --jq .id)
gh api -X PUT "repos/$REPO/environments/prod" --input - >/dev/null <<JSON
{"reviewers":[{"type":"User","id":$ME}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
JSON
gh api -X POST "repos/$REPO/environments/prod/deployment-branch-policies" -f name=main -f type=branch >/dev/null 2>&1 || true
echo "Environment prod: reviewer = you, branch = main"

# Secret scanning + push protection: a push containing a credential is rejected.
gh api -X PATCH "repos/$REPO" --input - >/dev/null <<'JSON' && echo "Secret scanning + push protection: on"
{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}
JSON
# Workflows get a read-only token unless a job asks for more; they cannot approve PRs.
gh api -X PUT "repos/$REPO/actions/permissions/workflow" -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false >/dev/null
echo "Default workflow token: read-only"
# Only actions from GitHub, AWS and the pinned vendors used by the workflows may run.
gh api -X PUT "repos/$REPO/actions/permissions" -F enabled=true -f allowed_actions=selected >/dev/null
gh api -X PUT "repos/$REPO/actions/permissions/selected-actions" --input - >/dev/null <<'JSON' && echo "Allowed actions: GitHub + pinned vendors only"
{"github_owned_allowed":true,"verified_allowed":false,"patterns_allowed":["aws-actions/*","docker/*","hashicorp/*","aquasecurity/*","sigstore/*","terraform-linters/*","gitleaks/*","grafana/*","hadolint/*"]}
JSON
