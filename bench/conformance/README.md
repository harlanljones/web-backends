# Conformance runner

The gate every framework must pass before it is a benchmark *result* rather
than an example. It drives a running app through the contract in
`contracts/openapi.yaml` and asserts the response shapes.

## Usage

```bash
# A framework is running (e.g. after bench/scripts/run-trial.sh go --keep)
python3 bench/conformance/run.py --url http://127.0.0.1:8080 --verbose
```

Options:

- `--url` — base URL of the app under test (default `http://127.0.0.1:8080`).
- `--wait N` — seconds to poll `/health` before giving up (default 30; give
  Spring/ASP.NET more, since their cold start is slower).
- `--verbose` / `-v` — print each check as it runs.

Exit status:

- `0` — all nine checks passed.
- `1` — at least one check failed.
- `2` — the app did not respond within the wait window.

## The nine checks

| # | Check | What it proves |
| --- | --- | --- |
| 1 | `/health` returns `200 {"status":"ok"}` | liveness, no DB round trip |
| 2 | `/json` returns the static shape | the serialization floor |
| 3 | `/products/1` returns a full `Product` | read path + type fidelity |
| 4 | `/products/999999999` returns `404` | a missing row is a distinct outcome |
| 5 | `/metrics` exposes the contracted histogram | the recording rule can read it |
| 6 | `/dashboard` returns `text/html` with a `<table>` | server-side render |
| 7 | `/orders` returns `201` with items | the transactional write |
| 8 | `/orders` without `Idempotency-Key` returns `400` | idempotency is required |
| 9 | `/orders` replays under the same key | no duplicate row |

Schema validation is deliberately light — required keys and types, not the
full JSON Schema spec — so a permissive framework cannot "round-trip" its way
through a permissive validator.

## Relationship to the load generator

Conformance runs *before* a measurement trial. The k6 load generator asserts
only status codes (and a couple of content checks); the conformance runner is
where the JSON shape, the idempotency replay, and the metric-name contract are
enforced. A framework must pass here first; load generation is not a substitute.
