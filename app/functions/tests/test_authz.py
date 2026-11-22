import os
import sys
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
os.environ["REQUIRE_ORIGIN_VERIFY"] = "true"

import common  # noqa: E402


class NotFound(Exception):
    pass


class FakeSM:
    """Minimal Secrets Manager double with version stages."""

    class exceptions:
        ResourceNotFoundException = NotFound

    def __init__(self, stages):
        self.stages = stages  # {stage: (version_id, value)}

    def get_secret_value(self, SecretId, VersionStage, VersionId=None):
        if VersionStage not in self.stages:
            raise NotFound("ResourceNotFoundException")
        vid, val = self.stages[VersionStage]
        return {"VersionId": vid, "SecretString": val}


def secret(stages):
    return common.VersionedSecret("s", client=FakeSM(stages))


ARN = "arn:aws:execute-api:eu-west-3:111111111111:abc123/live/{}/{}"


class TokenTests(unittest.TestCase):
    def setUp(self):
        self.key = secret({"AWSCURRENT": ("v2", "k" * 64), "AWSPREVIOUS": ("v1", "p" * 64)})

    def claims(self, **kw):
        now = int(time.time())
        c = {"iss": "soge", "aud": "soge", "sub": "u1", "iat": now, "exp": now + 300}
        c.update(kw)
        return c

    def test_roundtrip_current_and_previous_key(self):
        for kid, k in (("v2", "k" * 64), ("v1", "p" * 64)):
            tok = common.sign(self.claims(), kid, k)
            self.assertEqual(common.verify(tok, self.key)["sub"], "u1")

    def test_rejects_tampering_alg_none_and_expiry(self):
        tok = common.sign(self.claims(), "v2", "k" * 64)
        h, p, s = tok.split(".")
        forged = common.b64e(b'{"alg":"none","kid":"v2"}') + "." + p + "." + s
        for bad in (h + "." + p + "." + s[:-2] + "AA", forged, common.sign(self.claims(), "v9", "x" * 64)):
            with self.assertRaises(common.TokenError):
                common.verify(bad, self.key)
        old = common.sign(self.claims(exp=int(time.time()) - 10), "v2", "k" * 64)
        with self.assertRaises(common.TokenError):
            common.verify(old, self.key)
        self.assertEqual(common.verify(old, self.key, leeway=60)["sub"], "u1")

    def test_wrong_audience(self):
        with self.assertRaises(common.TokenError):
            common.verify(common.sign(self.claims(aud="other"), "v2", "k" * 64), self.key)


class AuthorizerTests(unittest.TestCase):
    def setUp(self):
        import authorizer

        self.a = authorizer
        authorizer._jwt_key = secret({"AWSCURRENT": ("v2", "k" * 64)})
        authorizer._origin = secret({"AWSCURRENT": ("o1", "origin-cur"), "AWSPENDING": ("o2", "origin-new")})

    def ev(self, method, path, **headers):
        return {"methodArn": ARN.format(method, path), "headers": headers}

    def test_origin_header_required_and_pending_accepted(self):
        with self.assertRaises(Exception):
            self.a.handler(self.ev("GET", "index.html"), None)
        r = self.a.handler(self.ev("GET", "index.html", **{"X-Origin-Verify": "origin-new"}), None)
        self.assertEqual(r["policyDocument"]["Statement"][0]["Effect"], "Allow")

    def test_jwt_required_on_protected_routes(self):
        hdr = {"X-Origin-Verify": "origin-cur"}
        with self.assertRaises(Exception):
            self.a.handler(self.ev("GET", "x/q", **hdr), None)
        now = int(time.time())
        tok = common.sign({"iss": "soge", "aud": "soge", "sub": "alice", "iat": now, "exp": now + 60}, "v2", "k" * 64)
        r = self.a.handler(self.ev("POST", "x/d", Authorization="Bearer " + tok, **hdr), None)
        self.assertEqual(r["principalId"], "alice")
        self.assertEqual(r["context"]["sub"], "alice")
        res = r["policyDocument"]["Statement"][0]["Resource"]
        self.assertTrue(all(x.endswith(("/x/q", "/x/d")) for x in res))


class IssuerTests(unittest.TestCase):
    def test_renewal_keeps_subject(self):
        import issuer

        issuer._key = secret({"AWSCURRENT": ("v2", "k" * 64)})
        first = __import__("json").loads(issuer.handler({"headers": {}}, None)["body"])
        claims = common.verify(first["token"], issuer._key)
        renewed = __import__("json").loads(issuer.handler({"headers": {"Authorization": "Bearer " + first["token"]}}, None)["body"])
        self.assertTrue(renewed["renewed"])
        self.assertEqual(common.verify(renewed["token"], issuer._key)["sub"], claims["sub"])


class RotatorTests(unittest.TestCase):
    def test_origin_rotation_pushes_header_then_promotes(self):
        import rotator

        rotator.KIND, rotator.DISTRIBUTION_ID = "origin", "E123"
        calls = []

        class SM(FakeSM):
            def __init__(self):
                super().__init__({})
                self.pending = None

            def describe_secret(self, SecretId):
                return {"RotationEnabled": True, "VersionIdsToStages": {"cur": ["AWSCURRENT"], "tok": ["AWSPENDING"]}}

            def get_secret_value(self, SecretId, VersionStage, VersionId=None):
                if self.pending is None:
                    raise NotFound()
                return {"VersionId": "tok", "SecretString": self.pending}

            def put_secret_value(self, **kw):
                self.pending = kw["SecretString"]

            def update_secret_version_stage(self, **kw):
                calls.append(("promote", kw["MoveToVersionId"]))

        class CF:
            cfg = {"Origins": {"Items": [{"Id": "apigw", "CustomHeaders": {"Quantity": 1, "Items": [{"HeaderName": "X-Origin-Verify", "HeaderValue": "old"}]}}]}}

            def get_distribution_config(self, Id):
                return {"DistributionConfig": self.cfg, "ETag": "e1"}

            def update_distribution(self, Id, IfMatch, DistributionConfig):
                calls.append(("cf", DistributionConfig["Origins"]["Items"][0]["CustomHeaders"]["Items"][0]["HeaderValue"]))
                self.cfg = DistributionConfig

        sm, cf = SM(), CF()
        for step in ("createSecret", "setSecret", "testSecret", "finishSecret"):
            rotator.handler({"SecretId": "arn", "ClientRequestToken": "tok", "Step": step}, None, sm=sm, cf=cf)
        self.assertEqual(calls[0][0], "cf")
        self.assertEqual(calls[0][1], sm.pending)
        self.assertGreaterEqual(len(sm.pending), 64)
        self.assertEqual(calls[1], ("promote", "tok"))


if __name__ == "__main__":
    unittest.main()
