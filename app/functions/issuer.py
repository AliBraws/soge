"""Session token issuer (POST /x/s, Lambda proxy integration).

* New visitor  -> new pseudonymous subject, 5-minute token.
* Renewal      -> the caller presents its current token (valid signature, may be
  expired by up to RENEW_GRACE seconds): same subject, fresh expiry.

In production this endpoint is replaced by the bank's IdP (OIDC); the
authorizer would then validate IdP-issued tokens against its JWKS. The
rotation / renewal mechanics stay identical.
"""
from __future__ import annotations

import json
import os
import time
import uuid

from common import TokenError, VersionedSecret, sign, verify, ISSUER, AUDIENCE

TTL = int(os.environ.get("TOKEN_TTL", "300"))
RENEW_GRACE = int(os.environ.get("RENEW_GRACE", "3600"))

_key = VersionedSecret(os.environ.get("JWT_SECRET_ID", ""))


def _resp(code: int, body: dict) -> dict:
    return {
        "statusCode": code,
        "headers": {"Content-Type": "application/json", "Cache-Control": "no-store"},
        "body": json.dumps(body),
    }


def handler(event, _ctx):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    sub = None
    auth = headers.get("authorization", "")
    if auth.startswith("Bearer "):
        try:
            sub = verify(auth[7:], _key, leeway=RENEW_GRACE)["sub"]
        except TokenError:
            sub = None  # unknown / too old: start a fresh session
    now = int(time.time())
    claims = {"iss": ISSUER, "aud": AUDIENCE, "sub": sub or str(uuid.uuid4()), "iat": now, "exp": now + TTL, "jti": str(uuid.uuid4())}
    kid, key = _key.current()
    return _resp(200, {"token": sign(claims, kid, key), "expires_in": TTL, "renewed": sub is not None})
