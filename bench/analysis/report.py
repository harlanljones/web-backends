#!/usr/bin/env python3
"""Generate the published benchmark report.

Consumes `compare.py --json-output` plus the qualitative meta and
renders a self-contained HTML report at
`docs/results/<date>-bench/index.html`.

The report has five parts:

  1. Header + methodology link
  2. Decision matrix (measured vs qualitative, never conflated)
  3. Per-framework deep-dive
  4. Framework-selection guide (decision rules by constraint)
  5. Dashboard + reference codebases + raw-data appendix

Usage:
    report.py --compare compare.json                     # uses meta yaml
    report.py --compare compare.json --meta meta.yaml
    report.py --compare compare.json --out docs/results/x
    report.py --compare compare.json --raw-dir ./runs    # inline raw data
"""
import argparse
import html
import json
import os
import sys
from datetime import date
from typing import Optional

# The constraints the framework-selection guide addresses, from the
# project brief. Each maps a constraint to the decision rule.
SELGUIDE = [
    ("Real-time statefulness",
     "Per-connection state, WebSockets, fan-in",
     "Choose a BEAM-based framework (Phoenix) or a goroutine-based one "
     "(Go); the actor model and goroutine-per-request handle long-lived "
     "state without a separate stateful service."),
    ("Compute-cost optimization",
     "Throughput per core, tail latency, memory",
     "Choose the highest RPS/core with p99.9 under the latency budget. "
     "Tie-break on CPU and RSS. (Axum and Go are typically the measured "
     "leaders here; the benchmark's measured section is authoritative.)"),
    ("Rapid team scaling",
     "Hiring pool, onboarding, ecosystem churn",
     "Choose a framework with a large hiring pool and low onboarding "
     "friction: Go, Node/Fastify, ASP.NET, or Python/FastAPI. Lower the "
     "ecosystem-friction score the more rapid the scaling."),
    ("Latency-sensitive interactive",
     "p99/p99.9 under interactive thresholds (<100ms)",
     "Prefer a compiled, low-overhead runtime (Go, Rust, ASP.NET). "
     "Interpreted runtimes (Python, Node/Bun) can meet the budget but "
     "have less headroom."),
    ("Durability of the choice",
     "The decision must survive ecosystem churn",
     "Prefer mature, widely-used frameworks (Go, Spring, ASP.NET, "
     "Fastify) over ones whose ecosystem is still settling "
     "(Bun/Hono, and to a lesser degree Axum/Tokio)."),
]


def load_yaml(path):
    try:
        import yaml
        with open(path) as f:
            return yaml.safe_load(f) or {}
    except ImportError:
        return parse_simple_yaml(path)


def parse_simple_yaml(path):
    out = {"frameworks": {}}
    current = None
    with open(path) as f:
        for line in f:
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            indent = len(line) - len(line.lstrip())
            line = line.strip()
            key, _, val = line.partition(":")
            key = key.strip().strip('"'); val = val.strip()
            if indent == 0 and key == "frameworks":
                continue
            if indent == 2:
                current = key; out["frameworks"][current] = {}
            elif current and indent >= 4 and val:
                if val in ("true", "false"):
                    v = val == "true"
                elif val.lstrip("-").replace(".", "", 1).isdigit() and key not in ("language", "name", "concurrency_model"):
                    v = int(val) if val.isdigit() else float(val)
                else:
                    v = val.strip('"').strip("'")
                out["frameworks"][current][key] = v
            elif current and indent >= 4:
                out["frameworks"][current][key] = True
    return out


def fnum(v: Optional[float], unit: str = "") -> str:
    if v is None:
        return "<em>n/a</em>"
    if abs(v) >= 100:
        s = f"{v:,.0f}"
    elif abs(v) >= 1:
        s = f"{v:.2f}"
    else:
        s = f"{v:.4f}"
    return f"{s} {unit}".strip()


def esc(s) -> str:
    return html.escape(str(s)) if s is not None else ""


def render_matrix(rows) -> str:
    h = ['<table class="matrix"><thead><tr>',
         '<th>Framework</th><th>Lang</th><th>RPS/core</th><th>p50</th>'
         '<th>p99</th><th>p99.9</th><th>Mem (MB)</th><th>CPU</th>'
         '<th>Friction</th>',
         '<th class="qual">Why it wins (qualitative)</th></tr></thead><tbody>']
    for r in rows:
        fw = r.get("name") or r.get("framework") or "?"
        lang = r.get("language") or ""
        h.append("<tr>")
        h.append(f"<td><strong>{esc(fw)}</strong></td>")
        h.append(f"<td>{esc(lang)}</td>")
        h.append(f"<td class='num'>{fnum(r['rps_per_core'].get('value'))}</td>")
        h.append(f"<td class='num'>{fnum(r['p50_ms'].get('value'), 'ms')}</td>")
        h.append(f"<td class='num'>{fnum(r['p99_ms'].get('value'), 'ms')}</td>")
        h.append(f"<td class='num'>{fnum(r['p999_ms'].get('value'), 'ms')}</td>")
        h.append(f"<td class='num'>{fnum(r['mem_mb'].get('value'))}</td>")
        h.append(f"<td class='num'>{fnum(r['cpu_core'].get('value'))}</td>")
        h.append(f"<td class='num'>{r.get('ecosystem_friction') or '-'}</td>")
        h.append(f"<td class='qual'>{esc(r.get('notes') or r.get('team_scaling') or '')}</td>")
        h.append("</tr>")
    h.append("</tbody></table>")
    return "".join(h)


def render_deep_dive(rows) -> str:
    blocks = []
    for r in rows:
        fw = r.get("name") or r.get("framework") or "?"
        concurrency = r.get("concurrency_model") or ""
        team = r.get("team_scaling") or ""
        blocks.append(f"""
<section class="framework">
  <h3>{esc(fw)} <span class="lang">{esc(r.get('language') or '')}</span></h3>
  <dl class="kv">
    <dt>Concurrency model</dt><dd>{esc(concurrency)}</dd>
    <dt>Throughput</dt><dd>{fnum(r['rps_per_core'].get('value'))} req/s/core</dd>
    <dt>Tail latency</dt><dd>p50 {fnum(r['p50_ms'].get('value'), 'ms')},
        p99 {fnum(r['p99_ms'].get('value'), 'ms')},
        p99.9 {fnum(r['p999_ms'].get('value'), 'ms')}</dd>
    <dt>Memory / CPU</dt><dd>{fnum(r['mem_mb'].get('value'))} MB RSS,
        {fnum(r['cpu_core'].get('value'))} cores</dd>
    <dt>Ecosystem friction</dt><dd>{r.get('ecosystem_friction') or 'n/a'}/5</dd>
  </dl>
  <p class="team">{esc(team)}</p>
  {('<p class="notes">' + esc(r.get('notes') or '') + '</p>') if r.get('notes') else ''}
</section>""")
    return "\n".join(blocks)


def render_selguide() -> str:
    rows = []
    for name, trigger, rule in SELGUIDE:
        rows.append(f"""<tr>
<td><strong>{esc(name)}</strong></td>
<td class="trig">{esc(trigger)}</td>
<td>{esc(rule)}</td></tr>""")
    return ('<table class="guide"><thead><tr><th>Constraint</th>'
            '<th>You need</th><th>Decision rule</th></tr></thead><tbody>'
            + "\n".join(rows) + "</tbody></table>")


def render_report(compare: dict, meta: dict, out_dir: str, notice: Optional[str] = None) -> str:
    rows = compare.get("frameworks", [])
    today = date.today().isoformat()

    # Sort by RPS/core descending for the matrix, keep a copy in the
    # meta order for the deep dive.
    matrix_rows = sorted(rows, key=lambda r: (r["rps_per_core"].get("value") or 0), reverse=True)

    banner = ""
    if notice:
        banner = (f'<div class="notice">{esc(notice)}</div>')

    body = f"""<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Modern Web Framework Benchmark — {today}</title>
<style>
:root {{ --ink:#222; --muted:#666; --accent:#2563eb; --border:#ddd; }}
body {{ font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif;
        color:var(--ink); max-width:1100px; margin:0 auto; padding:2rem 1.5rem;
        line-height:1.55; }}
h1 {{ font-size:1.8rem; margin-bottom:.2rem; }}
.sub {{ color:var(--muted); margin-bottom:1.5rem; }}
.notice {{ background:#fff7ed; border:1px solid #fdba74; border-left:4px solid #ea580c;
        color:#7c2d12; padding:.75rem 1rem; margin:1rem 0 1.5rem; border-radius:4px; }}
h2 {{ margin-top:2.5rem; border-bottom:2px solid var(--border); padding-bottom:.3rem; }}
table {{ border-collapse:collapse; width:100%; margin:1rem 0 2rem; font-size:.92rem; }}
th,td {{ padding:.5rem .6rem; border:1px solid var(--border); text-align:left; vertical-align:top; }}
th {{ background:#f5f5f5; }}
td.num {{ text-align:right; font-variant-numeric:tabular-nums; }}
td.qual {{ color:var(--muted); max-width:340px; }}
.lang {{ color:var(--muted); font-weight:normal; font-size:.85rem; }}
dl.kv {{ display:grid; grid-template-columns:180px 1fr; gap:.2rem .8rem; margin:0 0 .6rem; }}
dl.kv dt {{ font-weight:600; color:var(--muted); }}
.team, .notes {{ margin:.2rem 0 .4rem; color:var(--muted); }}
.badge {{ display:inline-block; background:var(--accent); color:#fff; border-radius:3px;
          padding:.1rem .4rem; font-size:.75rem; margin-right:.3rem; }}
.foot {{ margin-top:3rem; color:var(--muted); font-size:.85rem; border-top:1px solid var(--border); padding-top:1rem; }}
</style></head><body>
<h1>Modern Web Framework Performance &amp; Scalability Benchmark</h1>
<p class="sub">Published <strong>{today}</strong>. Methodology and reproducible
scripts live in the repository — see <code>docs/benchmark/</code> and
<code>bench/</code>.</p>
{banner}

<h2>1. Decision matrix</h2>
<p>Measured columns (RPS/core, p50/p99/p99.9, memory, CPU) come from the
benchmark runs. The final column (ecosystem friction) is qualitative and
is <strong>not</strong> a benchmark result — it is read alongside, never
blended into, the measured numbers.</p>
{render_matrix(matrix_rows)}

<h2>2. Per-framework deep dive</h2>
{render_deep_dive(rows)}

<h2>3. Framework-selection guide</h2>
<p>These rules turn the decision matrix into a recommendation given a
constraint. They are guidance, not a ranking: the right framework depends
on what the team optimizes for.</p>
{render_selguide()}

<h2>4. Dashboards and reference codebases</h2>
<ul>
<li><strong>Grafana dashboard</strong>: <code>infra/observability/grafana/dashboards/framework.json</code>
(throughput, latency percentiles, app/db CPU+memory, host pressure).</li>
<li><strong>Reference implementations</strong>: <code>apps/&lt;framework&gt;/</code>. Each is
contract-consistent and conformance-tested against
<code>contracts/openapi.yaml</code>; <code>apps/go/</code> is the reference.</li>
<li><strong>Load-test protocol</strong>: <code>bench/k6/</code> (warm-up, ramp, saturation).</li>
<li><strong>OpenAPI contract</strong>: <code>contracts/openapi.yaml</code>.</li>
</ul>

<h2>5. Raw data</h2>
<p>The numbers above are the aggregation of reproducible trials. The raw
per-trial output is under <code>runs/&lt;trial-id&gt;/</code>:
<code>manifest.json</code>, per-phase k6 summaries, Prometheus telemetry,
<code>pg_stat_statements.csv</code>, and the preflight host report. The
aggregation and comparison scripts are in
<code>bench/analysis/aggregate.py</code> and <code>bench/analysis/compare.py</code>.</p>
<details><summary>Expand the raw aggregated + compared data</summary>
<pre class="code">{esc(json.dumps(compare, indent=1))}</pre>
</details>

<p class="foot">Generated by <code>bench/analysis/report.py</code>. Measured
numbers are benchmark results; the ecosystem-friction and selection-guide
content is editorial guidance derived from the repository's
<code>bench/analysis/meta/frameworks.yaml</code>.</p>
</body></html>
"""
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "index.html")
    with open(path, "w") as f:
        f.write(body)
    return path


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.strip(), formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--compare", required=True, help="compare.py --json-output file")
    ap.add_argument("--meta", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "meta/frameworks.yaml"),
                    help="path to meta yaml")
    ap.add_argument("--out", default=None, help="output dir (default docs/results/<date>-bench)")
    ap.add_argument("--notice", default=None,
                    help="a caveat banner to render prominently at the top of the report")
    args = ap.parse_args()

    with open(args.compare) as f:
        compare = json.load(f)
    meta = load_yaml(args.meta)

    out_dir = args.out or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                                       "docs", "results", f"{date.today().isoformat()}-bench")
    out_dir = os.path.abspath(out_dir)

    path = render_report(compare, meta, out_dir, notice=args.notice)
    print(f"wrote {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
