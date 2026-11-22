"""Secrets Manager rotation function (4-step protocol) for two secret kinds:

* SECRET_KIND=jwt     JWT signing key. Nothing to push anywhere: issuer and
                      authorizer pick up the new version (kid) from the cache.
* SECRET_KIND=origin  CloudFront -> API Gateway origin-verify header. setSecret
                      pushes the pending value to the CloudFront origin custom
                      header; the authorizer already accepts AWSPENDING, so
                      there is no window where edge requests are rejected.

Terraform only ever writes a *bootstrap* value through a write-only argument
(``secret_string_wo``) fed by an ``ephemeral`` resource, and rotation is
triggered immediately: no live secret ever exists in the Terraform state.
"""
from __future__ import annotations

import logging
import os
import secrets

log = logging.getLogger()
log.setLevel(logging.INFO)

KIND = os.environ.get("SECRET_KIND", "jwt")
DISTRIBUTION_ID = os.environ.get("DISTRIBUTION_ID", "")
ORIGIN_ID = os.environ.get("ORIGIN_ID", "apigw")
HEADER = "X-Origin-Verify"


def _clients():
    import boto3

    return boto3.client("secretsmanager"), boto3.client("cloudfront")


def handler(event, _ctx, sm=None, cf=None):
    if sm is None:
        sm, cf = _clients()
    arn, token, step = event["SecretId"], event["ClientRequestToken"], event["Step"]

    meta = sm.describe_secret(SecretId=arn)
    if not meta.get("RotationEnabled"):
        raise ValueError("rotation not enabled")
    stages = meta["VersionIdsToStages"].get(token)
    if stages is None:
        raise ValueError("unknown version")
    if "AWSCURRENT" in stages:
        log.info("version already current, nothing to do")
        return
    if "AWSPENDING" not in stages:
        raise ValueError("version not pending")

    if step == "createSecret":
        try:
            sm.get_secret_value(SecretId=arn, VersionId=token, VersionStage="AWSPENDING")
        except sm.exceptions.ResourceNotFoundException:
            pw = secrets.token_urlsafe(48)  # 384 bits from the OS CSPRNG (no IAM "*" needed)
            sm.put_secret_value(SecretId=arn, ClientRequestToken=token, SecretString=pw, VersionStages=["AWSPENDING"])
    elif step == "setSecret":
        if KIND == "origin":
            pending = sm.get_secret_value(SecretId=arn, VersionId=token, VersionStage="AWSPENDING")["SecretString"]
            _push_to_cloudfront(cf, pending)
    elif step == "testSecret":
        if KIND == "origin":
            cfg = cf.get_distribution_config(Id=DISTRIBUTION_ID)["DistributionConfig"]
            pending = sm.get_secret_value(SecretId=arn, VersionId=token, VersionStage="AWSPENDING")["SecretString"]
            if _header_value(cfg) != pending:
                raise RuntimeError("CloudFront header not updated")
    elif step == "finishSecret":
        current = next(v for v, s in meta["VersionIdsToStages"].items() if "AWSCURRENT" in s)
        sm.update_secret_version_stage(SecretId=arn, VersionStage="AWSCURRENT", MoveToVersionId=token, RemoveFromVersionId=current)
        log.info("rotation finished")
    else:
        raise ValueError(f"invalid step {step}")


def _header_value(cfg: dict) -> str | None:
    for o in cfg["Origins"]["Items"]:
        if o["Id"] == ORIGIN_ID:
            for h in o.get("CustomHeaders", {}).get("Items", []):
                if h["HeaderName"] == HEADER:
                    return h["HeaderValue"]
    return None


def _push_to_cloudfront(cf, value: str) -> None:
    r = cf.get_distribution_config(Id=DISTRIBUTION_ID)
    cfg, etag = r["DistributionConfig"], r["ETag"]
    for o in cfg["Origins"]["Items"]:
        if o["Id"] == ORIGIN_ID:
            items = [h for h in o.get("CustomHeaders", {}).get("Items", []) if h["HeaderName"] != HEADER]
            items.append({"HeaderName": HEADER, "HeaderValue": value})
            o["CustomHeaders"] = {"Quantity": len(items), "Items": items}
    cf.update_distribution(Id=DISTRIBUTION_ID, IfMatch=etag, DistributionConfig=cfg)
