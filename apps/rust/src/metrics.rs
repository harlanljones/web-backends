//! Prometheus metrics for the framework.
//!
//! The histogram is named http_request_duration_seconds_* so the
//! recording rule in infra/observability/prometheus/rules/bench.yml
//! (bench:app:http_request_duration:p99:rate1m) picks it up without
//! per-framework changes. The `path` label is the workload name, not
//! the URL pattern, so it stays low-cardinality.

use prometheus::{IntCounterVec, HistogramVec, Registry, TextEncoder, Encoder};
use std::sync::OnceLock;

pub struct Metrics {
    pub registry: Registry,
    pub request_duration: HistogramVec,
    pub requests_total: IntCounterVec,
}

pub fn default_registry() -> &'static Metrics {
    static METRICS: OnceLock<Metrics> = OnceLock::new();
    METRICS.get_or_init(|| {
        let registry = Registry::new();
        let request_duration = HistogramVec::new(
            prometheus::HistogramOpts::new(
                "http_request_duration_seconds",
                "End-to-end request latency in seconds",
            )
            .buckets(vec![
                0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2,
                0.5, 1.0, 2.0, 5.0,
            ]),
            &["path", "method", "status"],
        )
        .unwrap();
        let requests_total = IntCounterVec::new(
            prometheus::Opts::new("http_requests_total", "Total HTTP requests"),
            &["path", "method", "status"],
        )
        .unwrap();
        registry.register(Box::new(request_duration.clone())).unwrap();
        registry.register(Box::new(requests_total.clone())).unwrap();
        Metrics {
            registry,
            request_duration,
            requests_total,
        }
    })
}

pub fn render_metrics() -> String {
    let m = default_registry();
    let mut buffer = Vec::new();
    let encoder = TextEncoder::new();
    encoder.encode(&m.registry.gather(), &mut buffer).ok();
    String::from_utf8(buffer).unwrap_or_default()
}

/// Map a route's path template to a workload-name label.
/// Single source of truth so a new endpoint only needs registering here
/// and in the router.
pub fn workload_name(path: &str) -> &'static str {
    match path {
        "/json" => "json",
        "/products/:id" => "product_read",
        "/products/{id}" => "product_read",
        "/orders" => "order_write",
        "/dashboard" => "dashboard",
        "/health" | "/metrics" => "infra",
        _ => "other",
    }
}
