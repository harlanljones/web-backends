#!/usr/bin/env python3
"""Compare frameworks across the benchmark's dimensions.

Merges the MEASURED aggregate results (per-framework JSON produced by
bench/analysis/aggregate.py --json) with the QUALITATIVE context
(bench/analysis/meta/frameworks.yaml) into a decision matrix.

The report this drives has two clearly separated sections:

  * MEASURED  -- throughput, tail latency, memory, CPU, concurrency
                 behavior. From the benchmark runs only.
  * QUALITATIVE -- ecosystem friction, concurrency model, team
                 scaling. From the meta yaml only; NOT benchmark
                 results.

A framework's measured numbers and its qualitative traits are never
compared to each other; they are presented side by side so a reader
can weigh "it is 2x faster" against "you will need to hire for it".

Usage:
    compare.py --framework-results results/go.json \
               [results/rust.json ...] \
               [--meta bench/analysis/meta/frameworks.yaml] \
               [--catalog catalog.json]
    compare.py --json-output report.json

Inputs:
  --framework-results  one JSON per framework, the output of
                       `aggregate.py --json` (a single framework's
                       per-workload aggregated results). Optional if a
                       --catalog is given.
  --catalog            a JSON mapping framework -> path to that framework's
                       aggregate JSON, e.g. {"go": "results/go.json"}. If
                       given, --framework-results are ignored.
  --meta               the qualitative yaml (default
                       bench/analysis/meta/frameworks.yaml).
  --json-output        write the merged matrix as JSON instead of a table.
"""
import argparse
import glob
import json
import os
import sys
from typing import Optional


def load_yaml(path: str) -> dict:
    try:
        import yaml
    except ImportError:
        # Minimal YAML subset parser fallback. The meta file is simple
        # enough that a tiny parser suffices; prefer pyyaml when present.
        return parse_simple_yaml(path)
    with open(path) as f:
        d = yaml.safe_load(f)
    return d or {}


def parse_simple_yaml(path: str) -> dict:
    """Naive indentation-aware parser for the meta schema.

    Only supports plain key: value and nested mapping blocks, which is
    all the meta file uses. Keeps compare.py runnable without pyyaml.
    """
    out: dict = {"frameworks": {}}
    current = None
    with open(path) as f:
        for line in f:
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            indent = len(line) - len(line.lstrip())
            line = line.strip()
            key, _, val = line.partition(":")
            key = key.strip().strip('"')
            val = val.strip()
            if indent == 0 and key == "frameworks":
                continue
            if indent == 2:
                current = key
                out["frameworks"][current] = {}
            elif current and indent >= 4 and val:
                out["frameworks"][current][key] = unquote(val, key)
            elif current and indent >= 4:
                out["frameworks"][current][key] = True
    return out


def unquote(val: str, key: str) -> object:
    if val in ("true", "false"):
        return val == "true"
    if val.lstrip("-").replace(".", "", 1).isdigit() and key not in ("language", "name", "concurrency_model"):
        return int(val) if val.isdigit() else float(val)
    return val.strip('"').strip("'")


def load_aggregate(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def framework_slug(path: str) -> str:
    return os.path.splitext(os.path.basename(path))[0]


def metric_display(agg: dict, key: str) -> dict:
    """Extract a top-level numeric metric's mean/ci.

    agg is the aggregate.py --json envelope:
        {"trials_total": n, "discarded_burnin": n, "usable": n,
         "framework": "go", "cores": 28,
         "results": {
            "workloads": [ {"workload": "json", "rps": {...},
                            "rps_per_core": {...}, "latency": {...}} ],
            "resources": {"mem_mb": {...}, "cpu_part_of_one_core": {...}}
         }}
    This is used for the framework-level `resources` metrics (mem/cpu).
    """
    unit = {"mem_mb": "MB", "cpu_part_of_one_core": "core"}.get(key, "")
    result = {"value": None, "ci": None, "unit": unit}
    res = (agg.get("results") or {}).get("resources", {})
    if key in res:
        m = res[key]
        return {"value": m.get("mean"), "ci": m.get("ci95"), "n": m.get("n"), "unit": unit}
    return result


def metric_display_for_workload(agg: dict, workload: str, key: str) -> dict:
    """Pull a metric out of a specific workload's block.

    The results layout nests per-workload metrics under
    results.workloads[], keyed by row["workload"]. `key` matches either
    a top-level row metric (rps, rps_per_core) or a latency sub-metric
    (med_ms / p99_ms / p999_ms / ...).
    """
    unit = {"rps": "/s", "rps_per_core": "req/s/core", "med_ms": "ms",
            "p99_ms": "ms", "p999_ms": "ms", "avg_ms": "ms"}.get(key, "")
    for row in (agg.get("results") or {}).get("workloads", []):
        if row.get("workload") != workload:
            continue
        if key in row:
            m = row[key]
            return {"value": m.get("mean"), "ci": m.get("ci95"), "n": m.get("n"), "unit": unit}
        lat = row.get("latency", {})
        if key in lat:
            m = lat[key]
            return {"value": m.get("mean"), "ci": m.get("ci95"), "n": m.get("n"), "unit": unit}
    return {"value": None, "ci": None, "n": None, "unit": unit}


def compare_matrix(frameworks: list[str], aggregates: dict[str, dict],
                   meta: dict[str, dict]) -> list[dict]:
    """Build one row per framework; columns = dimensions."""
    # The measured dimensions reference the json workload by default
    # (serialization floor) plus a note for the per-workload view. A
    # fuller comparison includes every workload; the matrix here uses
    # the json workload's p99.9 and rps_per_core as the headline
    # cross-workload proxies, with a per-workload detail kept in the
    # report.
    rows = []
    for fw in frameworks:
        agg = aggregates.get(fw, {})
        q = meta.get(fw, {})
        rows.append({
            "framework": fw,
            "name": q.get("name") or fw,
            "language": q.get("language") or "",
            "concurrency_model": q.get("concurrency_model") or "",
            # measured (json workload headline)
            "rps_per_core": metric_display_for_workload(agg, "json", "rps_per_core"),
            "p50_ms": metric_display_for_workload(agg, "json", "med_ms"),
            "p99_ms": metric_display_for_workload(agg, "json", "p99_ms"),
            "p999_ms": metric_display_for_workload(agg, "json", "p999_ms"),
            # measured resources (app container)
            "mem_mb": metric_display(agg, "mem_mb"),
            "cpu_core": metric_display(agg, "cpu_part_of_one_core"),
            # qualitative
            "ecosystem_friction": q.get("ecosystem_friction"),
            "team_scaling": q.get("team_scaling") or "",
            "notes": q.get("notes") or "",
        })
    return rows


def emit_table(rows: list[dict]) -> None:
    print()
    print("DECISION MATRIX -- measured vs qualitative (side by side, never conflated)")
    print("=" * 108)
    print(f"{'framework':<20} {'rps/core':>9} {'p50':>7} {'p99':>7} {'p99.9':>7} "
          f"{'mem_MB':>8} {'cpu':>6} {'fric':>5}")
    print("-" * 108)
    for r in rows:
        rpc = fmt(r["rps_per_core"]["value"])
        p50 = fmt(r["p50_ms"]["value"])
        p99 = fmt(r["p99_ms"]["value"])
        p999 = fmt(r["p999_ms"]["value"])
        mem = fmt(r["mem_mb"]["value"])
        cpu = fmt(r["cpu_core"]["value"])
        fr = r["ecosystem_friction"]
        print(f"{r['name']:<20} {rpc:>9} {p50:>7} {p99:>7} {p999:>7} {mem:>8} {cpu:>6} {str(fr):>5}")
    print()
    print("MEASURED (json workload headline; per-workload detail in the report)")
    print("-" * 108)
    for r in rows:
        print(f"\n  {r['name']} ({r['language']})")
        print(f"    concurrency model: {r['concurrency_model']}")
        print(f"    throughput:  rps/core {fmt(r['rps_per_core']['value'])}")
        print(f"    tail latency: p50 {fmt(r['p50_ms']['value'])}ms, p99 {fmt(r['p99_ms']['value'])}ms, "
              f"p99.9 {fmt(r['p999_ms']['value'])}ms")
        print(f"    resources:   {fmt(r['mem_mb']['value'])} MB RSS, {fmt(r['cpu_core']['value'])} cores")
        print(f"    qualitative: ecosystem friction {r['ecosystem_friction']}/5")
    print()
    print("QUALITATIVE (ecosystem friction is editorial, not a benchmark result)")
    print("-" * 100)
    for r in rows:
        print(f"\n  {r['name']}")
        if r.get("team_scaling"):
            print(f"    team scaling: {r['team_scaling']}")
        if r.get("notes"):
            print(f"    notes:        {r['notes']}")
    print()


def fmt(v: Optional[float]) -> str:
    return "-" if v is None else (f"{v:.2f}" if abs(v) < 1000 else f"{v:.0f}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.strip(), formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--framework-results", nargs="*", default=[])
    ap.add_argument("--catalog", help="JSON mapping framework -> aggregate json path")
    ap.add_argument("--meta", default="bench/analysis/meta/frameworks.yaml")
    ap.add_argument("--json-output", help="write merged matrix as JSON")
    args = ap.parse_args()

    meta_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "meta/frameworks.yaml") \
        if args.meta == "bench/analysis/meta/frameworks.yaml" and not os.path.isfile(args.meta) \
        else args.meta
    meta = load_yaml(meta_path)
    meta_frameworks = meta.get("frameworks", {})

    # Resolve which aggregate files to read.
    filters: dict[str, str] = {}
    if args.catalog:
        with open(args.catalog) as f:
            filters = json.load(f)
        frameworks = list(filters.keys())
    else:
        filters = {framework_slug(p): p for p in args.framework_results}
        frameworks = list(filters.keys())

    if not frameworks and os.path.isdir("results"):
        # Auto-discover results/<fw>.json
        for p in sorted(glob.glob("results/*.json")):
            fw = os.path.splitext(os.path.basename(p))[0]
            filters[fw] = p
            frameworks.append(fw)

    if not frameworks:
        print("no framework results found; pass --framework-results or --catalog", file=sys.stderr)
        return 1

    aggregates = {}
    for fw in frameworks:
        path = filters.get(fw)
        if path and os.path.isfile(path):
            aggregates[fw] = load_aggregate(path)
        elif path:
            print(f"[warn] no aggregate json at {path}", file=sys.stderr)

    rows = compare_matrix(frameworks, aggregates, meta_frameworks)

    if args.json_output:
        with open(args.json_output, "w") as f:
            json.dump({
                "measured_dimensions": ["rps_per_core", "p50_ms", "p99_ms", "p999_ms", "mem_mb", "cpu_core"],
                "qualitative_dimensions": ["ecosystem_friction", "concurrency_model", "team_scaling"],
                "frameworks": rows,
            }, f, indent=2)
        print(f"wrote {args.json_output}")
        return 0

    emit_table(rows)
    return 0


if __name__ == "__main__":
    sys.exit(main())
