"""API Gateway REQUEST Lambda authorizer.

Two checks, both constant-time:
1. Origin verification (public API only, REQUIRE_ORIGIN_VERIFY=true): the
   X-Origin-Verify header must match a live version of the rotating secret that
   CloudFront injects. Calling the regional API directly (bypassing CloudFront,
   its WAF and its TLS policy) is therefore impossible.
2. JWT (routes under /x/q and /x/d): HS256, kid-based key lookup across the
   current and previous key versions, iss/aud/exp checks.

The returned policy is scoped to the minimum set of methods so that a cached
decision (authorizer TTL) can never be reused on a broader route.
"""
from __future__ import annotations

import json
import logging
import os

from common import TokenError, VersionedSecret, verify

log = logging.getLogger()
log.setLevel(logging.INFO)

REQUIRE_ORIGIN = os.environ.get("REQUIRE_ORIGIN_VERIFY", "false") == "true"
PROTECTED_PREFIXES = ("x/q", "x/d")

_jwt_key = VersionedSecret(os.environ.get("JWT_SECRET_ID", ""))
_origin = VersionedSecret(os.environ.get("ORIGIN_SECRET_ID", "")) if REQUIRE_ORIGIN else None


def _headers(event) -> dict:
    return {k.lower(): v for k, v in (event.get("headers") or {}).items()}


def _arn_parts(method_arn: str):
    # arn:aws:execute-api:{region}:{account}:{apiId}/{stage}/{METHOD}/{resource...}
    prefix, path = method_arn.split(":", 5)[:5], method_arn.split(":", 5)[5]
    api_id, stage, method, *resource = path.split("/")
    base = ":".join(prefix) + f":{api_id}/{stage}"
    return base, method, "/".join(resource)


def _policy(principal: str, effect: str, resources: list[str], context: dict | None = None) -> dict:
    out = {
        "principalId": principal,
        "policyDocument": {
            "Version": "2012-10-17",
            "Statement": [{"Action": "execute-api:Invoke", "Effect": effect, "Resource": resources}],
        },
    }
    if context:
        out["context"] = context
    return out


def handler(event, _ctx):
    base, method, resource = _arn_parts(event["methodArn"])
    h = _headers(event)

    if REQUIRE_ORIGIN and not _origin.matches(h.get("x-origin-verify", "")):
        log.warning(json.dumps({"decision": "deny", "reason": "origin", "resource": resource}))
        raise Exception("Unauthorized")  # API Gateway maps this exact message to 401

    if not resource.startswith(PROTECTED_PREFIXES):
        # Edge-only routes: static assets (GET) and the session endpoint.
        return _policy("edge", "Allow", [f"{base}/GET/*", f"{base}/POST/x/s"])

    auth = h.get("authorization", "")
    if not auth.startswith("Bearer "):
        raise Exception("Unauthorized")
    try:
        claims = verify(auth[7:], _jwt_key)
    except TokenError as exc:
        log.info(json.dumps({"decision": "deny", "reason": str(exc)}))
        raise Exception("Unauthorized") from None
    sub = str(claims["sub"])
    return _policy(sub, "Allow", [f"{base}/*/x/q", f"{base}/*/x/d"], {"sub": sub})
