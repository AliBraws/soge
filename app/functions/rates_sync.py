"""rates_sync: fetches the ECB daily reference rates and publishes a snapshot.

Scheduled every hour (EventBridge Scheduler; the ECB publishes once a day). Runs OUTSIDE the VPC on
purpose: it is the only component that needs the internet, so the VPC itself
keeps no route out (no IGW, no NAT). Its IAM role can do exactly one thing:
s3:PutObject on rates/latest.json (KMS-encrypted). The API reads that object
through the S3 gateway endpoint.

If the ECB is unreachable the previous snapshot stays in place: the API keeps
quoting and shows the snapshot date (degraded, not down).
"""
from __future__ import annotations

import json
import os
import re
import time
import urllib.request
import xml.etree.ElementTree as ET  # expat >= 2.4.1 in the runtime mitigates entity expansion

URL = os.environ.get("ECB_URL", "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")
BUCKET = os.environ.get("RATES_BUCKET", "")
KEY = os.environ.get("RATES_KEY", "rates/latest.json")
NS = "{http://www.ecb.int/vocabulary/2002-08-01/eurofxref}"
CCY = re.compile(r"^[A-Z]{3}$")


def parse(xml_bytes: bytes) -> tuple[str, dict[str, float]]:
    root = ET.fromstring(xml_bytes)
    day = root.find(f"{NS}Cube/{NS}Cube")
    if day is None:
        raise ValueError("unexpected ECB format")
    rates = {}
    for c in day.findall(f"{NS}Cube"):
        ccy, rate = c.get("currency", ""), float(c.get("rate", "0"))
        if CCY.match(ccy) and 0 < rate < 1_000_000:
            rates[ccy] = rate
    if len(rates) < 10 or not {"USD", "GBP", "JPY", "CHF"} <= rates.keys():
        raise ValueError(f"incomplete feed ({len(rates)} currencies)")
    return day.get("time", ""), rates


def handler(_event, _ctx, s3=None, opener=urllib.request.urlopen):
    if not URL.startswith("https://"):
        raise ValueError("https only")
    with opener(URL, timeout=5) as r:  # noqa: S310 (scheme checked above)
        as_of, rates = parse(r.read(1 << 20))
    body = json.dumps({"as_of": as_of, "fetched_at": int(time.time()), "rates": rates}).encode()
    if s3 is None:
        import boto3

        s3 = boto3.client("s3")
    s3.put_object(Bucket=BUCKET, Key=KEY, Body=body, ContentType="application/json",
                  ServerSideEncryption="aws:kms", CacheControl="no-cache")
    print(json.dumps({"msg": "rates published", "as_of": as_of, "count": len(rates)}))
    return {"as_of": as_of, "count": len(rates)}
