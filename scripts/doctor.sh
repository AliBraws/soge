#!/usr/bin/env bash
# Checks that the workstation, the AWS account and the DNS zone are ready.
# Uses only temporary credentials (aws login / IAM Identity Center), never an access key.
#   AWS_PROFILE=soge HOSTED_ZONE_ID=Z... ./scripts/doctor.sh
set -uo pipefail
REGION="${AWS_REGION:-eu-west-3}"
ok() { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
ko() { printf '  \033[31mKO\033[0m   %s\n' "$1"; FAILED=1; }
FAILED=0

echo "== tools"
need() { # name, command, minimum version
  if ! command -v "$1" >/dev/null 2>&1; then ko "$1 missing"; return; fi
  v=$($2 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
  if [ "$(printf '%s\n%s\n' "$3" "$v" | sort -V | head -1)" = "$3" ]; then ok "$1 $v (>= $3)"; else ko "$1 $v (< $3)"; fi
}
need terraform "terraform version" 1.17.0
need tflint "tflint --version" 0.66.0
need trivy "trivy --version" 0.76.0
need hadolint "hadolint --version" 2.15.0
need gitleaks "gitleaks version" 8.30.0
need go "go version" 1.27.0
need python3 "python3 --version" 3.14.0
need docker "docker version --format {{.Client.Version}}" 29.0.0
need k6 "k6 version" 2.0.0
need cosign "cosign version" 3.0.0
need aws "aws --version" 2.32.0
need gh "gh --version" 2.80.0
need jq "jq --version" 1.7
docker buildx version >/dev/null 2>&1 && ok "docker buildx" || ko "docker buildx missing"

echo "== AWS (temporary credentials only: aws login or IAM Identity Center)"
if ID=$(aws sts get-caller-identity --output json 2>/dev/null); then
  ok "identity: $(echo "$ID" | jq -r .Arn)"
  if aws configure export-credentials --format process 2>/dev/null | jq -e '.SessionToken and .Expiration' >/dev/null; then
    ok "temporary credentials (session token + expiry)"
  else ko "long-term credentials detected: use 'aws login' or 'aws sso login', never access keys"; fi
else ko "no AWS session: aws login --profile soge (or aws sso login)"; fi
[ -z "${AWS_ACCESS_KEY_ID:-}" ] && ok "no AWS_ACCESS_KEY_ID in the environment" || ko "AWS_ACCESS_KEY_ID is set: unset it, use aws login"
grep -qs aws_secret_access_key ~/.aws/credentials && ko "~/.aws/credentials contains a static key: remove it" || ok "no static key in ~/.aws/credentials"
AZS=$(aws ec2 describe-availability-zones --region "$REGION" --query 'length(AvailabilityZones[?State==`available`])' --output text 2>/dev/null)
[ "${AZS:-0}" -ge 3 ] && ok "$REGION reachable, $AZS AZs (an SCP region restriction would fail here)" || ko "$REGION not usable (SCP? permissions?)"
VPCS=$(aws ec2 describe-vpcs --region "$REGION" --query 'length(Vpcs)' --output text 2>/dev/null)
VPCMAX=$(aws service-quotas get-service-quota --region "$REGION" --service-code vpc --quota-code L-F678F1CE --query 'Quota.Value' --output text 2>/dev/null)
[ -n "$VPCS" ] && ok "VPCs in $REGION: $VPCS / ${VPCMAX:-5} (default VPC left untouched)"
FG=$(aws service-quotas get-service-quota --region "$REGION" --service-code fargate --quota-code L-3032A538 --query 'Quota.Value' --output text 2>/dev/null)
[ -n "$FG" ] && ok "Fargate on-demand vCPU quota: $FG (need >= 18 x 0.5 = 9 at full scale)"

echo "== DNS"
if [ -n "${HOSTED_ZONE_ID:-}" ]; then
  ZONE=$(aws route53 get-hosted-zone --id "$HOSTED_ZONE_ID" --query 'HostedZone.Name' --output text 2>/dev/null)
  if [ -n "$ZONE" ] && [ "$ZONE" != "None" ]; then
    ok "hosted zone $HOSTED_ZONE_ID = $ZONE"
    AWSNS=$(aws route53 get-hosted-zone --id "$HOSTED_ZONE_ID" --query 'DelegationSet.NameServers' --output text | tr '\t' '\n' | sort)
    PUBNS=$(dig +short NS "${ZONE%.}" @1.1.1.1 | sed 's/\.$//' | sort)
    [ -n "$PUBNS" ] && [ "$AWSNS" = "$PUBNS" ] && ok "delegation OK: public NS = Route 53 NS (ACM validation will work)" || ko "public NS of ${ZONE%.} do not match the zone's NS: ACM validation would hang"
  else ko "hosted zone $HOSTED_ZONE_ID not found"; fi
else ko "HOSTED_ZONE_ID not set"; fi

echo "== GitHub"
gh auth status >/dev/null 2>&1 && ok "gh authenticated" || ko "gh auth login"

echo
[ "$FAILED" = 0 ] && echo "Ready." || { echo "Fix the KO lines above."; exit 1; }
