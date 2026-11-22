"""Shared helpers: versioned secrets cache + compact HS256 JWT.

Key rotation model
------------------
* The signing key lives in Secrets Manager and is rotated automatically
  (rotator.py). The JWT ``kid`` is the Secrets Manager VersionId.
* Tokens are always signed with AWSCURRENT.
* Verification accepts AWSCURRENT and AWSPREVIOUS, so a rotation never
  invalidates tokens in flight (token TTL 5 min << rotation period).
* The origin-verify secret also accepts AWSPENDING, because CloudFront is
  updated with the pending value before the stage moves (setSecret step).

Standard library only (+ boto3 provided by the Lambda runtime): no third-party
dependency to patch, nothing to vendor.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import time

STAGES = ("AWSCURRENT", "AWSPREVIOUS", "AWSPENDING")
CACHE_TTL = int(os.environ.get("SECRET_CACHE_TTL", "60"))
ISSUER = os.environ.get("TOKEN_ISSUER", "soge")
AUDIENCE = os.environ.get("TOKEN_AUDIENCE", "soge")

_client = None


def sm_client():
    global _client
    if _client is None:
        import boto3  # provided by the runtime; imported lazily for unit tests

        _client = boto3.client("secretsmanager")
    return _client


class VersionedSecret:
    """Caches every live version of a secret: {stage: (version_id, value)}."""

    def __init__(self, secret_id: str, client=None):
        self.secret_id = secret_id
        self._client = client
        self._versions: dict[str, tuple[str, str]] = {}
        self._loaded_at = 0.0

    def _sm(self):
        return self._client or sm_client()

    def refresh(self) -> None:
        versions = {}
        for stage in STAGES:
            try:
                r = self._sm().get_secret_value(SecretId=self.secret_id, VersionStage=stage)
                versions[stage] = (r["VersionId"], r["SecretString"])
            except Exception as exc:  # stage may legitimately not exist
                if "ResourceNotFound" not in type(exc).__name__ and "ResourceNotFound" not in str(exc):
                    if stage == "AWSCURRENT":
                        raise
        self._versions, self._loaded_at = versions, time.time()

    def _fresh(self):
        if time.time() - self._loaded_at > CACHE_TTL or "AWSCURRENT" not in self._versions:
            self.refresh()

    def current(self) -> tuple[str, str]:
        self._fresh()
        return self._versions["AWSCURRENT"]

    def by_kid(self, kid: str, stages=("AWSCURRENT", "AWSPREVIOUS")) -> str | None:
        self._fresh()
        for _ in range(2):  # unknown kid => a rotation just happened, reload once
            for st in stages:
                v = self._versions.get(st)
                if v and v[0] == kid:
                    return v[1]
            self.refresh()
        return None

    def matches(self, candidate: str, stages=STAGES) -> bool:
        self._fresh()
        ok = False
        for st in stages:
            v = self._versions.get(st)
            if v:  # constant time, evaluate all
                ok |= hmac.compare_digest(v[1].encode(), candidate.encode())
        return ok


def b64e(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def b64d(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


class TokenError(Exception):
    pass


def sign(claims: dict, kid: str, key: str) -> str:
    header = {"alg": "HS256", "typ": "JWT", "kid": kid}
    h = b64e(json.dumps(header, separators=(",", ":")).encode())
    p = b64e(json.dumps(claims, separators=(",", ":")).encode())
    sig = hmac.new(key.encode(), f"{h}.{p}".encode(), hashlib.sha256).digest()
    return f"{h}.{p}.{b64e(sig)}"


def verify(token: str, secret: VersionedSecret, now: float | None = None, leeway: int = 0) -> dict:
    """Verify signature, algorithm, issuer, audience and expiry.

    ``leeway`` lets the issuer accept a recently expired token for renewal.
    """
    now = time.time() if now is None else now
    try:
        h, p, s = token.split(".")
        header = json.loads(b64d(h))
        claims = json.loads(b64d(p))
    except Exception as exc:
        raise TokenError("malformed") from exc
    if header.get("alg") != "HS256":  # never trust the token's alg (alg=none attack)
        raise TokenError("alg")
    key = secret.by_kid(str(header.get("kid", "")))
    if key is None:
        raise TokenError("unknown kid")
    expected = hmac.new(key.encode(), f"{h}.{p}".encode(), hashlib.sha256).digest()
    if not hmac.compare_digest(expected, b64d(s)):
        raise TokenError("signature")
    if claims.get("iss") != ISSUER or claims.get("aud") != AUDIENCE:
        raise TokenError("iss/aud")
    if now > float(claims.get("exp", 0)) + leeway or now + 30 < float(claims.get("iat", 0)):
        raise TokenError("expired")
    return claims
