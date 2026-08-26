//! Axum on Rust/Tokio reference implementation of the benchmark contract.
//!
//! Implements the four workloads + /health + /metrics against
//! contracts/openapi.yaml. Uses axum + sqlx (postgres) + the prometheus
//! crate. The three contract environment variables (DATABASE_URL,
//! DB_POOL_SIZE, LOG_LEVEL) are read at startup and held constant.
//!
//! Deliberately not done:
//!   * No caching. A framework that caches /products/:id would look
//!     faster and lie about it; the contract forbids it implicitly.
//!   * No extra pool on top of sqlx. sqlx's pool is the throughput lever.
//!   * No per-request logging. tracing is leveled at WARN, so at 10k RPS
//!     the log budget stays within the contract.

mod config;
mod db;
mod handlers;
mod metrics;
mod models;

use axum::{
    extract::DefaultBodyLimit,
    middleware::{self, Next},
    routing::{get, post},
    Router,
};
use axum::http::Request;
use axum::response::Response;
use std::time::Instant;

#[tokio::main]
async fn main() {
    let cfg = match config::Config::from_env() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("startup failed: {e}");
            std::process::exit(1);
        }
    };

    let filter = config::log_filter(&cfg.log_level);
    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(false)
        .json()
        .init();

    tracing::info!(
        framework = "rust-axum",
        db_pool_size = cfg.db_pool_size,
        port = %cfg.port,
        log_level = %cfg.log_level,
        "starting bench app"
    );

    let pool = db::make_pool(&cfg)
        .await
        .unwrap_or_else(|e| {
            tracing::error!("database pool failed: {e}");
            std::process::exit(1);
        });
    tracing::info!("database pool ready");

    let state = handlers::AppState { pool };

    let router = Router::new()
        .route("/json", get(handlers::get_json))
        .route("/products/:id", get(handlers::get_product))
        .route("/orders", post(handlers::create_order))
        .route("/dashboard", get(handlers::get_dashboard))
        .route("/health", get(handlers::get_health))
        .route("/metrics", get(handlers::get_metrics))
        // The middleware records the workload-labeled histogram. This is
        // the framework's server-side view, scraped by Prometheus.
        .layer(middleware::from_fn(track_latency))
        // A generous body limit. The contract caps /orders items at 20.
        .layer(DefaultBodyLimit::max(1 << 20))
        .with_state(state);

    let addr = format!("0.0.0.0:{}", cfg.port);
    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .unwrap_or_else(|e| {
            tracing::error!("bind {addr}: {e}");
            std::process::exit(1);
        });
    tracing::info!(%addr, "listening");
    axum::serve(listener, router)
        .await
        .unwrap_or_else(|e| {
            tracing::error!("serve: {e}");
            std::process::exit(1);
        });
}

/// Record the workload-labeled latency histogram in the Prometheus metrics.
async fn track_latency(
    req: Request<axum::body::Body>,
    next: Next,
) -> Response {
    let start = Instant::now();
    let path = req.uri().path().to_string();
    let method = req.method().as_str().to_string();

    let resp = next.run(req).await;

    // Normalize the path: axum uses :param, the contract uses {param}.
    let norm = normalize_path(&path);
    let workload = metrics::workload_name(&norm);
    let status = resp.status().as_u16().to_string();
    let m = metrics::default_registry();
    m.request_duration
        .with_label_values(&[workload, &method, &status])
        .observe(start.elapsed().as_secs_f64());
    m.requests_total
        .with_label_values(&[workload, &method, &status])
        .inc();
    resp
}

fn normalize_path(path: &str) -> &str {
    // The route template and the request path differ for parameterized
    // routes. To keep the label low-cardinality, we never use the raw
    // path; we only label known workload prefixes. For anything else we
    // fall back to "other".
    if path.contains("/products/") {
        "/products/:id"
    } else {
        path
    }
}
