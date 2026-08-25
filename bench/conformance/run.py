#!/usr/bin/env python3
"""Drive a running benchmark app through the contract in
contracts/openapi.yaml and assert the response shapes.

Each test makes one HTTP call. The test passes if:

- the status code matches the OpenAPI definition for the input, and
- the response body, when JSON, conforms to the schema for that endpoint.

Schema validation is intentionally light: we check the keys and types
listed as required in contracts/openapi.yaml, not the full JSON Schema
specification. A full validator would let frameworks that round-trip
"a very permissive schema" sneak through.

Exit status:
    0  every test passed
    1  at least one test failed
    2  the app did not respond at all
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import uuid
from typing import Any, Callable
from urllib.parse import urljoin
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

# Required keys for each endpoint, derived from the OpenAPI components.
# Keeping the table here (rather than parsing openapi.yaml at runtime) makes
# the conformance runner's expectations visible at a glance.
REQUIRED_JSON_KEYS: dict[str, set[str]] = {
    "/json": {"service", "version", "time"},
    "/products/{id}": {"id", "sku", "name", "description", "category_id",
                       "price_cents", "stock", "active"},
    "/orders": {"id", "customer_id", "status", "total_cents", "items"},
    "/dashboard": set(),  # HTML, not JSON
    "/health": {"status"},
    "/metrics": set(),  # text
}

# A test is (name, method, path, query, body, expected_status, validator,
# skip_idempotency_key).
#
# `skip_idempotency_key` is True for tests that must NOT have the
# Idempotency-Key header auto-supplied. The "required" test is the obvious
# case: it asserts that the server rejects requests without the key.
#
# `expected_status == 0` is a sentinel meaning "the validator makes its
# own calls; the runner must not call the endpoint first". Used by the
# idempotency-replay test, which must use the *same* key for both calls.
Test = tuple[str, str, str, dict | None, dict | None, int,
             Callable[[int, bytes, dict[str, str]], None] | None,
             bool]


def http(method: str, url: str, body: dict | None, headers: dict[str, str]) -> tuple[int, bytes, dict[str, str]]:
    data = json.dumps(body).encode() if body is not None else None
    req = Request(url, data=data, method=method, headers={"Content-Type": "application/json", **headers})
    try:
        with urlopen(req, timeout=5) as resp:
            return resp.status, resp.read(), dict(resp.headers)
    except HTTPError as e:
        return e.code, e.read() if e.fp else b"", dict(e.headers or {})


def test_health(base: str) -> Test:
    def validate(status: int, body: bytes, _hdr: dict[str, str]) -> None:
        if status != 200:
            raise AssertionError(f"status {status}, want 200")
        payload = json.loads(body)
        missing = REQUIRED_JSON_KEYS["/health"] - payload.keys()
        if missing:
            raise AssertionError(f"missing keys: {missing}")
        if payload["status"] != "ok":
            raise AssertionError(f"status field was {payload['status']!r}")
    return ("health returns 200 ok", "GET", "/health", None, None, 200, validate, False)


def test_json(base: str) -> Test:
    def validate(status: int, body: bytes, _hdr: dict[str, str]) -> None:
        if status != 200:
            raise AssertionError(f"status {status}, want 200")
        payload = json.loads(body)
        missing = REQUIRED_JSON_KEYS["/json"] - payload.keys()
        if missing:
            raise AssertionError(f"missing keys: {missing}")
        for k in ("service", "version", "time"):
            if not isinstance(payload[k], str):
                raise AssertionError(f"{k} should be a string, got {type(payload[k])}")
    return ("/json returns the static shape", "GET", "/json", None, None, 200, validate, False)


def test_product_ok(base: str) -> Test:
    def validate(status: int, body: bytes, _hdr: dict[str, str]) -> None:
        if status != 200:
            raise AssertionError(f"status {status}, want 200")
        payload = json.loads(body)
        missing = REQUIRED_JSON_KEYS["/products/{id}"] - payload.keys()
        if missing:
            raise AssertionError(f"missing keys: {missing}")
        for k in ("id", "sku", "name", "description", "category_id", "price_cents", "stock"):
            if not isinstance(payload[k], (int, str)):
                raise AssertionError(f"{k} unexpected type {type(payload[k])}")
        if not isinstance(payload["active"], bool):
            raise AssertionError("active should be a bool")
    return ("/products/1 returns a Product", "GET", "/products/1", None, None, 200, validate, False)


def test_product_404(base: str) -> Test:
    def validate(status: int, body: bytes, _hdr: dict[str, str]) -> None:
        if status != 404:
            raise AssertionError(f"status {status}, want 404")
    return ("/products/999999999 returns 404", "GET", "/products/999999999", None, None, 404, validate, False)


def test_metrics(base: str) -> Test:
    def validate(status: int, body: bytes, hdr: dict[str, str]) -> None:
        if status != 200:
            raise AssertionError(f"status {status}, want 200")
        # The Prometheus text format must contain our histogram. The exact
        # name is part of the contract.
        text = body.decode("utf-8", errors="replace")
        if "http_request_duration_seconds_bucket" not in text:
            raise AssertionError("metrics output does not contain the contracted histogram")
    return ("/metrics exposes the contract histogram", "GET", "/metrics", None, None, 200, validate, False)


def test_dashboard(base: str) -> Test:
    def validate(status: int, body: bytes, hdr: dict[str, str]) -> None:
        if status != 200:
            raise AssertionError(f"status {status}, want 200")
        ct = hdr.get("Content-Type", "")
        if "text/html" not in ct:
            raise AssertionError(f"Content-Type was {ct!r}, expected text/html")
        text = body.decode("utf-8", errors="replace")
        if "<table" not in text:
            raise AssertionError("dashboard HTML did not contain a <table>")
    return ("/dashboard returns HTML with a table", "GET", "/dashboard", None, None, 200, validate, False)


def test_order_create(base: str) -> Test:
    body = {
        "customer_id": 1,
        "items": [
            {"product_id": 1, "quantity": 1},
            {"product_id": 2, "quantity": 1},
        ],
    }
    def validate(status: int, body_bytes: bytes, _hdr: dict[str, str]) -> None:
        if status != 201:
            raise AssertionError(f"status {status}, want 201, body={body_bytes!r}")
        payload = json.loads(body_bytes)
        missing = REQUIRED_JSON_KEYS["/orders"] - payload.keys()
        if missing:
            raise AssertionError(f"missing keys: {missing}")
        if payload["status"] != "pending":
            raise AssertionError(f"status was {payload['status']!r}")
        if not isinstance(payload["items"], list) or len(payload["items"]) != 2:
            raise AssertionError(f"items should be a list of 2, got {payload['items']!r}")
    return ("/orders creates a 201 with items", "POST", "/orders", None, body, 201, validate, False)


def test_order_idempotent(base: str) -> Test:
    """Replay the same Idempotency-Key; the response should be the same order.

    The Test validator is responsible for making both calls itself because
    the second call must use the *same* Idempotency-Key as the first. The
    runner's auto-supply logic would otherwise generate a fresh key per
    call. The sentinel `expected_status == 0` (and `skip_idempotency_key`)
    tells the runner to skip the outer call and trust the validator.
    """
    body = {
        "customer_id": 1,
        "items": [{"product_id": 3, "quantity": 1}],
    }

    def call(idem_key: str) -> dict:
        status, b, _ = http("POST", urljoin(base, "/orders"), body,
                            {"Idempotency-Key": idem_key})
        if status != 201:
            raise AssertionError(f"call returned status {status}, body {b!r}")
        return json.loads(b)

    def validate(_status: int, _body: bytes, _hdr: dict[str, str]) -> None:
        idem = str(uuid.uuid4())
        first = call(idem)
        second = call(idem)
        if first["id"] != second["id"]:
            raise AssertionError(
                f"replay returned a different id: first={first['id']} second={second['id']}"
            )

    return ("/orders replays under the same Idempotency-Key", "POST", "/orders",
            None, body, 0, validate, True)


def test_order_idempotency_required(base: str) -> Test:
    body = {"customer_id": 1, "items": [{"product_id": 4, "quantity": 1}]}
    def validate(status: int, body_bytes: bytes, _hdr: dict[str, str]) -> None:
        if status != 400:
            raise AssertionError(f"status {status}, want 400, body={body_bytes!r}")
    return ("/orders without Idempotency-Key returns 400", "POST", "/orders",
            None, body, 400, validate, True)


def build_tests(base: str) -> list[Test]:
    return [
        test_health(base),
        test_json(base),
        test_product_ok(base),
        test_product_404(base),
        test_metrics(base),
        test_dashboard(base),
        test_order_create(base),
        test_order_idempotency_required(base),
        test_order_idempotent(base),
    ]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8080",
                    help="Base URL of the app under test (default: http://127.0.0.1:8080)")
    ap.add_argument("--wait", type=int, default=30,
                    help="Seconds to wait for /health to be 200 before giving up")
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()

    # Wait for the app to be up. The trial driver has already done this
    # once, but the harness can be run on its own.
    deadline = time.monotonic() + args.wait
    while time.monotonic() < deadline:
        try:
            status, _, _ = http("GET", urljoin(args.url, "/health"), None, {})
            if status == 200:
                break
        except (URLError, OSError):
            pass
        time.sleep(0.5)
    else:
        print(f"FAIL: app did not respond at {args.url} within {args.wait}s", file=sys.stderr)
        return 2

    tests = build_tests(args.url)
    passed = 0
    failed = 0
    for name, method, path, _q, body, want, validator, skip_idem in tests:
        url = urljoin(args.url, path)
        headers: dict[str, str] = {}
        if not skip_idem and method == "POST" and path == "/orders":
            headers["Idempotency-Key"] = str(uuid.uuid4())
        try:
            if want == 0:
                # Sentinel: the test runs entirely inside the validator
                # because the second call must use the same key as the
                # first. The runner's auto-supply is bypassed by setting
                # skip_idem on the test.
                if validator:
                    validator(0, b"", {})
                passed += 1
                if args.verbose:
                    print(f"  PASS {name}")
                continue

            status, response, hdr = http(method, url, body, headers)
            if status != want:
                raise AssertionError(f"status {status}, want {want}, body={response[:200]!r}")
            if validator:
                validator(status, response, hdr)
            passed += 1
            if args.verbose:
                print(f"  PASS {name}")
        except (AssertionError, ValueError) as e:
            failed += 1
            print(f"  FAIL {name}: {e}", file=sys.stderr)
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"  ERROR {name}: {type(e).__name__}: {e}", file=sys.stderr)

    print(f"\n{passed} passed, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
