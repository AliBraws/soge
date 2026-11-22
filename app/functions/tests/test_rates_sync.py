import io
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import rates_sync  # noqa: E402

FEED = b"""<?xml version="1.0" encoding="UTF-8"?>
<gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
<Cube><Cube time='2026-11-18'>""" + b"".join(
    f"<Cube currency='{c}' rate='{r}'/>".encode()
    for c, r in [("USD", 1.08), ("JPY", 161.2), ("GBP", 0.85), ("CHF", 0.94), ("SEK", 11.5), ("NOK", 11.7),
                 ("DKK", 7.46), ("PLN", 4.3), ("CZK", 25.1), ("HUF", 400.1), ("AUD", 1.65)]
) + b"</Cube></Cube></gesmes:Envelope>"


class RatesSyncTests(unittest.TestCase):
    def test_parse_and_publish(self):
        put = {}

        class S3:
            def put_object(self, **kw):
                put.update(kw)

        out = rates_sync.handler({}, None, s3=S3(), opener=lambda url, timeout: io.BytesIO(FEED))
        self.assertEqual(out["as_of"], "2026-11-18")
        self.assertEqual(put["ServerSideEncryption"], "aws:kms")
        self.assertIn(b'"USD": 1.08', put["Body"])

    def test_rejects_incomplete_feed(self):
        with self.assertRaises(ValueError):
            rates_sync.parse(FEED.replace(b"currency='USD'", b"currency='usd'"))


if __name__ == "__main__":
    unittest.main()
