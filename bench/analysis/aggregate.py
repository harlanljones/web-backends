#!/usr/bin/env python3
"""Aggregate benchmark trial results into a comparison table.

Reads one or more campaign trial directories (as produced by
bench/scripts/exec-trial.sh), discards burn-in trials, grabs the
saturation-phase k6 summary for each workload, and computes the
per-workload metrics aggregated across the measured trials with a 95%
confidence interval.

The output is a table of the headline numbers the project asks for:

    peak RPS, RPS per CPU core, p50, p95, p99, p99.9, max latency,
    error rate, VU count

plus the mean-of-trials and a 95% confidence interval for each metric
and workload.

Usage:
    aggregate.py <trial-dir> [<trial-dir> ...]
    aggregate.py --framework go --runs ./runs
    aggregate.py --list-campaigns ./runs

Each trial-dir may be absolute, "runs/<trial-id>", or a bare trial-id
resolved against --runs.
"""
import argparse
import glob
import json
import math
import os
import re
import sys
from typing import Any, Optional

# The workloads, in the order the contract defines them. The k6
# scenario tags carry these as `workload:<name>`.
WORKLOADS = ["json", "product_read", "order_write", "dashboard"]

# 95% confidence interval critical values for Student's t distribution.
# Indexed by (n - 1) degrees of freedom, for n up to 20. For n < 2 the
# CI is undefined (we report the single value).
T_95 = {
    1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447,
    7: 2.365, 8: 2.306, 9: 2.262, 10: 2.228, 11: 2.201, 12: 2.179,
    13: 2.160, 14: 2.145, 15: 2.131, 16: 2.120, 17: 2.110, 18: 2.101,
    19: 2.093,
}


def is_burnin(trial_dir: str) -> bool:
    """A burn-in trial is identified by its trial-id suffix."""
    baseline = os.path.basename(os.path.normpath(trial_dir))
    return bool(re.search(r"burnin|burn-in|_burnin", baseline, re.I))


def load_saturation_summary(trial_dir: str) -> Optional[dict]:
    path = os.path.join(trial_dir, "saturation", "k6-summary.json")
    if not os.path.isfile(path):
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def k6_metric(summary: dict, name: str) -> Optional[dict]:
    """Get a metric object from a k6 summary by exact name."""
    metrics = summary.get("metrics", {})
    if name in metrics:
        return metrics[name]
    # The per-workload histograms carry a tag selector in the metric
    # name, e.g. http_req_duration{workload:json}. The caller passes
    # the exact name.
    return None


def metric_value(minfo: Optional[dict], key: str) -> Optional[float]:
    """Get a value from a k6 metric object.

    A k6 metric object stores its aggregated stats under `values`:
        {"type": "counter", "values": {"count": 32, "rate": 10.66}}
        {"type": "trend",   "values": {"avg": 0.1, "p(95)": 0.2, ...}}
    So an exact key (e.g. `count`) is at minfo["values"][key]. The
    histogram percentiles (avg/med/p(90)/p(99)/p(99.9)/max) are also
    under `values`.
    """
    if not minfo or not isinstance(minfo, dict):
        return None
    vals = minfo.get("values")
    if isinstance(vals, dict) and key in vals:
        v = vals[key]
        return float(v) if v is not None else None
    v = minfo.get(key)
    return float(v) if v is not None else None


def workload_metric(summary: dict, workload: str) -> Optional[dict]:
    # The k6 summary stores per-workload histogram metrics under the
    # exact key http_req_duration{workload:<name>}.
    key = f"http_req_duration{{workload:{workload}}}"
    return k6_metric(summary, key)


def trial_workload_row(summary: dict, workload: str) -> Optional[dict]:
    m = workload_metric(summary, workload)
    if m is None:
        return None
    return {
        "workload": workload,
        "avg_ms": metric_value(m, "avg"),
        "med_ms": metric_value(m, "med"),
        "p90_ms": metric_value(m, "p(90)"),
        "p95_ms": metric_value(m, "p(95)"),
        "p99_ms": metric_value(m, "p(99)"),
        "p999_ms": metric_value(m, "p(99.9)"),
        "max_ms": metric_value(m, "max"),
    }


def workload_check_count(summary: dict, workload: str, primary_check: str) -> Optional[int]:
    """Count the passes of a workload's primary status check.

    k6's summary `root_group.checks` holds per-check pass/fail counts.
    The per-workload throughput is the number of iterations that
    reached the primary status check for that workload, which is the
    cleanest per-workload iteration count in the summary. The primary
    check name is workload-specific (e.g. 'json: status 200').
    """
    checks = ((summary.get("root_group") or {}).get("checks")) or []
    for c in checks:
        if c.get("name") == primary_check:
            return int(c.get("passes", 0)) + int(c.get("fails", 0))
    return None


# The primary status check name per workload, matching lib/endpoints.js.
PRIMARY_CHECK = {
    "json": "json: status 200",
    "product_read": "product_read: status 200 or 404",
    "order_write": "order_write: status 201",
    "dashboard": "dashboard: status 200",
}


def telemetry_series(trial_dir: str, match) -> list[float]:
    """Flatten the values of every telemetry series whose metric matches.

    The telemetry collector stores one .json per PromQL under
    `telemetry/`. Each holds the Prometheus `query_range` response: a
    matrix with per-series `values` as [ [ts, value], ... ]. `match` is
    a predicate over a series' metric label dict.
    """
    values: list[float] = []
    tdir = os.path.join(trial_dir, "telemetry")
    if not os.path.isdir(tdir):
        return values
    for name in os.listdir(tdir):
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(tdir, name)) as f:
                d = json.load(f)
        except (OSError, ValueError):
            continue
        for series in (d.get("data") or {}).get("result", []):
            if not match(series.get("metric", {})):
                continue
            for _, val in series.get("values", []):
                try:
                    values.append(float(val))
                except (TypeError, ValueError):
                    continue
    return values


def parse_telemetry_metrics(trial_dir: str) -> dict:
    """Read memory and CPU for the app container from telemetry series.

    Returns {"mem_mb": mean RSS in MB, "cpu_cores": mean CPU in cores}.
    None where the series was not captured.

    The two series must be told apart, not just matched on the container
    name: `container_memory_rss` (bytes, has __name__) vs the cAdvisor
    CPU rate `rate(container_cpu_usage_seconds_total{...})` (cores/s;
    its query_range result carries no __name__ but does carry the `cpu`
    label). Both share `name="bench-app"`.
    """
    mem_vals = telemetry_series(
        trial_dir,
        lambda m: m.get("__name__") == "container_memory_rss" and m.get("name") == "bench-app",
    )
    cpu_vals = telemetry_series(
        trial_dir,
        lambda m: m.get("name") == "bench-app" and "cpu" in m,
    )
    return {
        "mem_mb": round(mean(mem_vals) / 1024 / 1024, 1) if mem_vals else None,
        "cpu_cores": round(mean(cpu_vals), 4) if cpu_vals else None,
    }


def load_trial(trial_dir: str) -> Optional[dict]:
    """Extract everything aggregate needs from one trial directory."""
    manifest_path = os.path.join(trial_dir, "manifest.json")
    if not os.path.isfile(manifest_path):
        return None
    with open(manifest_path) as f:
        manifest = json.load(f)

    summary = load_saturation_summary(trial_dir)
    if summary is None:
        return None

    # Framework from the manifest image tag (bench/<fw>:latest) or the
    # trial-id prefix.
    image = manifest.get("framework_image", "")
    m = re.match(r"bench/([^:]+)", image)
    framework = m.group(1) if m else None

    # Cores for RPS/core. The app node's *allocated* cores (APP_CPUS, the
    # cpuset the app container is pinned to) is the correct denominator;
    # the host's nproc (what preflight records) overstates it on any host
    # that also runs other roles or a desktop. Prefer the manifest's
    # app_cores, fall back to the app-node preflight cpu_count.
    cores = None
    config = manifest.get("config") or {}
    if config.get("app_cores"):
        try:
            cores = int(config["app_cores"])
        except (TypeError, ValueError):
            cores = None
    if cores is None:
        for role in ("app", "db", "loadgen"):
            pf_path = os.path.join(trial_dir, f"preflight-{role}.json")
            if os.path.isfile(pf_path):
                try:
                    with open(pf_path) as pf:
                        pfdata = json.load(pf)
                    cc = None
                    for c in pfdata.get("checks", []):
                        if c.get("name") == "cpu_count":
                            cc = c.get("observed")
                    if cc and str(cc).strip().isdigit():
                        cores = int(str(cc).strip())
                        if role == "app":
                            break
                except (OSError, ValueError):
                    pass

    # Throughput from the k6 summary. The aggregated http_reqs count
    # gives total iterations; divide by the saturation duration for
    # the RPS. The per-workload count is the authoritative RPS for the
    # workload.
    metrics = summary.get("metrics", {})
    reqs = metric_value(k6_metric(summary, "http_reqs"), "count") or 0
    sat_window = (manifest.get("saturation") or {})
    dur_s = parse_window_seconds(sat_window.get("started_at"), sat_window.get("ended_at"))

    # Per-workload RPS = that workload's iteration count / saturation
    # seconds. The count comes from the primary status check's
    # passes+fails in the summary's root_group, which is the per-
    # workload iteration count.
    workloads = {}
    for w in WORKLOADS:
        cnt = workload_check_count(summary, w, PRIMARY_CHECK.get(w, ""))
        workloads[w] = {
            "rps": round(cnt / dur_s, 2) if cnt is not None and dur_s else None,
            "iterations": cnt,
            "latency": trial_workload_row(summary, w),
        }

    telemetry = parse_telemetry_metrics(trial_dir)
    return {
        "trial_dir": os.path.abspath(trial_dir),
        "trial_id": os.path.basename(os.path.normpath(trial_dir)),
        "framework": framework or image,
        "burn_in": is_burnin(os.path.basename(os.path.normpath(trial_dir))),
        "image": image,
        "rps_total": round(reqs / dur_s, 2) if dur_s else None,
        "saturation_seconds": dur_s,
        "cores": cores,
        "mem_mb": telemetry.get("mem_mb"),
        "cpu_cores": telemetry.get("cpu_cores"),
        "preflight_failed": manifest.get("preflight_failed"),
        "status": manifest.get("status"),
        "workloads": workloads,
    }


def parse_window_seconds(start: Optional[str], end: Optional[str]) -> Optional[float]:
    if not start or not end:
        return None
    try:
        from datetime import datetime, timezone

        def to_ts(s: str) -> float:
            s = s.strip()
            # ISO-8601 with offset, e.g. 2026-08-25T14:41:01-07:00
            try:
                return datetime.fromisoformat(s).timestamp()
            except ValueError:
                return float(s) if s.replace(".", "", 1).lstrip("-").isdigit() else 0.0

        return to_ts(end) - to_ts(start)
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Aggregation across trials
# ---------------------------------------------------------------------------
def mean(xs: list[float]) -> Optional[float]:
    return sum(xs) / len(xs) if xs else None


def stdev(xs: list[float]) -> float:
    if len(xs) < 2:
        return 0.0
    m = mean(xs)
    return math.sqrt(sum((x - m) ** 2 for x in xs) / (len(xs) - 1))


def ci95(xs: list[float]) -> Optional[float]:
    """95% confidence interval half-width around the mean."""
    n = len(xs)
    if n < 2:
        return None
    t = T_95.get(n - 1, 1.96 if n > 19 else 1.96)
    return t * stdev(xs) / math.sqrt(n)


def aggregate(values: list[Optional[float]]) -> dict:
    xs = [v for v in values if v is not None]
    return {
        "n": len(xs),
        "mean": mean(xs),
        "ci95": ci95(xs),
        "min": min(xs) if xs else None,
        "max": max(xs) if xs else None,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.strip(), formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trial_dirs", nargs="*", help="trial dirs, ids, or paths")
    ap.add_argument("--framework", help="filter to this framework (from the image tag)")
    ap.add_argument("--runs", default="runs", help="root runs/ dir for bare trial-ids")
    ap.add_argument("--list-campaigns", help="list trial-id prefixes in --runs")
    ap.add_argument("--no-ci", action="store_true", help="skip CI (single trial)")
    ap.add_argument("--json", action="store_true", help="emit JSON not a table")
    args = ap.parse_args()

    if args.list_campaigns:
        return list_campaigns(args.runs)

    # Resolve trial dirs.
    dirs: list[str] = []
    for td in args.trial_dirs:
        d = resolve_dir(td, args.runs)
        if d is None:
            print(f"[warn] no manifest at {td}", file=sys.stderr)
            continue
        dirs.append(d)

    if not dirs:
        # Auto-discover campaigns under runs/ if nothing given.
        dirs = sorted(glob.glob(os.path.join(args.runs, "*", "manifest.json")))
        dirs = [os.path.dirname(d) for d in dirs]

    # Load each trial.
    trials = []
    for d in dirs:
        t = load_trial(d)
        if t is None:
            continue
        if args.framework and t["framework"] != args.framework:
            continue
        trials.append(t)

    if not trials:
        print("no trials found", file=sys.stderr)
        return 1

    # Separate measured vs burn-in. Measured = not burn-in AND status
    # indicates a completed run. Burn-in is discarded.
    discarded = [t for t in trials if t["burn_in"]]
    measured = [t for t in trials if not t["burn_in"]]

    # Also drop trials whose saturation summary had no data (status or
    # zero RPS) -- those are not usable measurements.
    usable = [t for t in measured if (t["rps_total"] or 0) > 0]
    skipped = [t for t in measured if (t["rps_total"] or 0) <= 0]

    if args.json:
        sys.stdout.write(json.dumps({
            "trials_total": len(trials),
            "discarded_burnin": len(discarded),
            "skipped_no_data": len(skipped),
            "usable": len(usable),
            "framework": (usable[0]["framework"] if usable else None),
            "cores": (usable[0].get("cores") if usable else None),
            "results": build_results(usable),
        }, indent=2) + "\n")
    else:
        emit_table(discarded, skipped, usable)

    return 0


def resolve_dir(td: str, runs_root: str) -> Optional[str]:
    td = td.rstrip("/")
    if os.path.isabs(td):
        return td if os.path.isfile(os.path.join(td, "manifest.json")) else None
    if td.startswith("runs/"):
        d = os.path.abspath(td)
        return d if os.path.isfile(os.path.join(d, "manifest.json")) else None
    d = os.path.join(os.path.abspath(runs_root), td)
    return d if os.path.isfile(os.path.join(d, "manifest.json")) else None


def build_results(usable: list[dict]) -> list[dict]:
    """Aggregate the usable trials; one row per workload."""
    out = []
    # Core count is constant across trials of a framework; take the
    # majority value for RPS/core.
    core_vals = [t.get("cores") for t in usable if t.get("cores")]
    cores = sorted(set(core_vals))[:1] if core_vals else None
    for w in WORKLOADS:
        per_trial = [t["workloads"].get(w) for t in usable]
        # RPS
        rps = [pt.get("rps") for pt in per_trial if pt and pt.get("rps") is not None]
        # RPS per core
        rps_core = [pt.get("rps") / core_vals[0] for pt, _ in zip(per_trial, usable)
                    if pt and pt.get("rps") is not None and core_vals and core_vals[0]]
        # Latency percentiles (ms)
        lat_metrics = [
            (p, [(pt.get("latency") or {}).get(p) for pt in per_trial
                 if pt and (pt.get("latency") or {}).get(p) is not None])
            for p in ("avg_ms", "med_ms", "p90_ms", "p95_ms", "p99_ms", "p999_ms", "max_ms")
        ]
        out.append({
            "workload": w,
            "cores": cores[0] if cores else None,
            "rps": aggregate(rps),
            "rps_per_core": aggregate(rps_core),
            "latency": {k: aggregate(v) for k, v in lat_metrics},
        })
    # Framework-level resource summary (memory, CPU), aggregated across
    # the used trials.
    mem = [t.get("mem_mb") for t in usable if t.get("mem_mb") is not None]
    cpu = [t.get("cpu_cores") for t in usable if t.get("cpu_cores") is not None]
    return {
        "workloads": out,
        "resources": {
            "mem_mb": aggregate(mem),
            "cpu_cores": aggregate(cpu),
        },
    }


def emit_table(discarded, skipped, usable) -> None:
    print(f"trials: {len(discarded) + len(usable) + len(skipped)} total, "
          f"{len(discarded)} burn-in discarded, {len(skipped)} no-data skipped, "
          f"{len(usable)} aggregated")
    if discarded:
        print(f"  discarded: {', '.join(t['trial_id'] for t in discarded)}")
    if skipped:
        print(f"  skipped:   {', '.join(t['trial_id'] for t in skipped)}")
    print()

    # Framework-level resource summary first, then one block per workload.
    accs = build_results(usable)
    res = accs.get("resources", {})
    print(f"=== resources (app container, mean over saturation) ===")
    print(f"{'metric':<12} {'n':<2} {'mean':>12} {'CI95':>12} {'min':>12} {'max':>12}")
    if res.get("mem_mb", {}).get("n"):
        m = res["mem_mb"]
        print(f"{'mem_mb':<12} {m['n']:<2} {fmt(m['mean']):>12} {fmt(m['ci95']):>12} "
              f"{fmt(m['min']):>12} {fmt(m['max']):>12}")
    if res.get("cpu_cores", {}).get("n"):
        c = res["cpu_cores"]
        print(f"{'cpu_core':<12} {c['n']:<2} {fmt(c['mean']):>12} {fmt(c['ci95']):>12} "
              f"{fmt(c['min']):>12} {fmt(c['max']):>12}")
    print()

    for w in WORKLOADS:
        print(f"=== {w} ===")
        print(f"{'metric':<12} {'n':<2} {'mean':>12} {'CI95':>12} {'min':>12} {'max':>12}")
        row = next((r for r in accs["workloads"] if r["workload"] == w), None)
        if not row:
            print("  (no data)")
            print()
            continue
        rps = row["rps"]
        rpc = row["rps_per_core"]
        print(f"{'rps':<12} {rps['n']:<2} {fmt(rps['mean']):>12} {fmt(rps['ci95']):>12} "
              f"{fmt(rps['min']):>12} {fmt(rps['max']):>12}")
        if rpc.get("mean") is not None:
            print(f"{'rps/core':<12} {rpc['n']:<2} {fmt(rpc['mean']):>12} {fmt(rpc['ci95']):>12} "
                  f"{fmt(rpc['min']):>12} {fmt(rpc['max']):>12}  ({row.get('cores')} cores)")
        for k, a in row["latency"].items():
            if a["n"] == 0:
                continue
            print(f"{k:<12} {a['n']:<2} {fmt(a['mean']):>12} {fmt(a['ci95']):>12} "
                  f"{fmt(a['min']):>12} {fmt(a['max']):>12}")
        print()


def fmt(v: Optional[float]) -> str:
    if v is None:
        return "-"
    if abs(v) >= 100:
        return f"{v:.0f}"
    if abs(v) >= 1:
        return f"{v:.2f}"
    return f"{v:.4f}"


def list_campaigns(runs_root: str) -> int:
    trials = sorted(glob.glob(os.path.join(runs_root, "*", "manifest.json")))
    prefixes: dict[str, int] = {}
    for d in trials:
        tid = os.path.basename(os.path.dirname(d))
        # Strip the -trial-N suffix to group by campaign.
        prefix = re.sub(r"-trial-\d+.*$", "", tid)
        prefixes[prefix] = prefixes.get(prefix, 0) + 1
    for p, n in sorted(prefixes.items()):
        print(f"{p:<40} {n} trial(s)")
    if not prefixes:
        print("no campaigns in runs/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
