// Prometheus metrics for the framework.
//
// The histogram is named http_request_duration_seconds_* so the recording
// rule in infra/observability/prometheus/rules/bench.yml
// (bench:app:http_request_duration:p99:rate1m) picks it up without
// per-framework changes.
//
// The `path` label is normalized to the workload's logical name, not the
// URL pattern. That is the difference between "GET /products/{id}" (a
// parameterized URL) and "product_read" (a workload name). Without
// normalization, a high-cardinality label would explode Prometheus; with
// it, the histogram is comparable across every framework.
package main

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

var (
	httpRequestDuration = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "End-to-end request latency, in seconds.",
			Buckets: []float64{0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5},
		},
		// path is the workload name, e.g. "json", "product_read",
		// "order_write", "dashboard".
		[]string{"path", "method", "status"},
	)
)

// workloadName maps the gin route's full path to the workload name used as a
// Prometheus label. Keeping this in one place means a new endpoint only has
// to be registered once, here and in main.
func workloadName(ginPath string) string {
	switch ginPath {
	case "/json":
		return "json"
	case "/products/:id":
		return "product_read"
	case "/orders":
		return "order_write"
	case "/dashboard":
		return "dashboard"
	case "/health", "/metrics":
		return "infra"
	default:
		// Uncontracted path. Falls under the dashboard's "everything else"
		// panel; the four contracted workloads are the only ones that
		// publish.
		return "other"
	}
}
