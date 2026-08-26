//! HTTP handlers for the four workloads + /health + /metrics + middleware.

use axum::extract::{Path, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::Json;
use chrono::Utc;
use sqlx::{PgPool, Row};
use uuid::Uuid;

use crate::metrics;
use crate::models::*;

/// Shared app state.
#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
}

// ---------------------------------------------------------------------------
// /json
// ---------------------------------------------------------------------------

pub async fn get_json() -> Json<JsonResponse> {
    Json(JsonResponse {
        service: "bench",
        version: "1.0.0",
        time: Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Nanos, true),
    })
}

// ---------------------------------------------------------------------------
// /products/{id}
// ---------------------------------------------------------------------------

const PRODUCT_SELECT: &str = "SELECT id, sku, name, description, category_id, \
    price_cents, stock, active FROM products WHERE id = $1";

pub async fn get_product(
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> Result<Json<Product>, (StatusCode, Json<serde_json::Value>)> {
    let row = sqlx::query(PRODUCT_SELECT)
        .bind(id)
        .fetch_optional(&state.pool)
        .await
        .map_err(internal_error)?;

    match row {
        Some(r) => Ok(Json(Product {
            id: r.get("id"),
            sku: r.get("sku"),
            name: r.get("name"),
            description: r.get("description"),
            category_id: r.get("category_id"),
            price_cents: r.get("price_cents"),
            stock: r.get("stock"),
            active: r.get("active"),
        })),
        None => Err((
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"error": "not found"})),
        )),
    }
}

// ---------------------------------------------------------------------------
// /orders
// ---------------------------------------------------------------------------

pub async fn create_order(
    State(state): State<AppState>,
    headers: HeaderMap,
    // The request body is parsed as JSON by the extractor.
    Json(req): Json<OrderRequest>,
) -> Result<(StatusCode, Json<Order>), (StatusCode, Json<serde_json::Value>)> {
    let idem_key = headers
        .get("Idempotency-Key")
        .and_then(|v| v.to_str().ok())
        .ok_or_else(|| {
            (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"error": "Idempotency-Key header is required"})),
            )
        })?;

    if req.items.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": "items must be non-empty"})),
        ));
    }

    // Validate the idempotency key is a UUID. The database column is
    // uuid; an invalid value would be a 500 from Postgres.
    let idem_uuid = Uuid::parse_str(idem_key).map_err(|_| {
        (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": "invalid Idempotency-Key"})),
        )
    })?;

    // Open a transaction.
    let mut tx = state.pool.begin().await.map_err(internal_error)?;

    // Lock product rows in id order to avoid deadlocks under
    // concurrent overlapping requests.
    let mut product_ids: Vec<i64> = req.items.iter().map(|i| i.product_id).collect();
    product_ids.sort_unstable();
    product_ids.dedup();

    // prices map: product_id -> price_cents and stock.
    struct LockedRow {
        price: i32,
        stock: i32,
    }
    let mut prices: std::collections::HashMap<i64, LockedRow> = Default::default();
    for pid in &product_ids {
        let row = sqlx::query("SELECT price_cents, stock FROM products WHERE id = $1 FOR UPDATE")
            .bind(pid)
            .fetch_optional(&mut *tx)
            .await
            .map_err(internal_error)?;
        match row {
            Some(r) => {
                prices.insert(*pid, LockedRow {
                    price: r.get("price_cents"),
                    stock: r.get("stock"),
                });
            }
            None => {
                return Err((
                    StatusCode::BAD_REQUEST,
                    Json(serde_json::json!({"error": "unknown product", "product_id": pid})),
                ));
            }
        }
    }

    // Check stock and compute the total.
    let mut total: i64 = 0;
    for it in &req.items {
        let p = prices.get(&it.product_id).ok_or_else(|| {
            (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"error": "unknown product"})),
            )
        })?;
        if p.stock < it.quantity {
            return Err((
                StatusCode::CONFLICT,
                Json(serde_json::json!({
                    "error": "insufficient stock",
                    "product_id": it.product_id,
                    "available": p.stock,
                    "requested": it.quantity,
                })),
            ));
        }
        total += p.price as i64 * it.quantity as i64;
    }

    // Insert the order. On idempotency-key conflict, read the original.
    let order_id: i64 = match sqlx::query(
        "INSERT INTO orders (customer_id, status, total_cents, idempotency_key) \
         VALUES ($1, 'pending', $2, $3) \
         ON CONFLICT (idempotency_key) DO NOTHING RETURNING id",
    )
    .bind(req.customer_id)
    .bind(total)
    .bind(idem_uuid)
    .fetch_optional(&mut *tx)
    .await
    .map_err(internal_error)?
    {
        Some(r) => r.get("id"),
        None => {
            // Replay: roll back the (empty) tx and return the original order.
            tx.rollback().await.map_err(internal_error)?;
            return replay_order(&state.pool, idem_uuid).await;
        }
    };

    // Insert items, ledger rows, and decrement stock.
    for it in &req.items {
        let p = prices.get(&it.product_id).unwrap();
        sqlx::query(
            "INSERT INTO order_items (order_id, product_id, quantity, unit_price_cents) \
             VALUES ($1, $2, $3, $4)",
        )
        .bind(order_id)
        .bind(it.product_id)
        .bind(it.quantity)
        .bind(p.price)
        .execute(&mut *tx)
        .await
        .map_err(internal_error)?;

        sqlx::query("INSERT INTO inventory_ledger (product_id, order_id, delta) VALUES ($1, $2, $3)")
            .bind(it.product_id)
            .bind(order_id)
            .bind(-it.quantity)
            .execute(&mut *tx)
            .await
            .map_err(internal_error)?;

        sqlx::query("UPDATE products SET stock = stock - $1, updated_at = now() WHERE id = $2")
            .bind(it.quantity)
            .bind(it.product_id)
            .execute(&mut *tx)
            .await
            .map_err(internal_error)?;
    }

    tx.commit().await.map_err(internal_error)?;

    let items: Vec<OrderItem> = req
        .items
        .iter()
        .map(|it| OrderItem {
            product_id: it.product_id,
            quantity: it.quantity,
            unit_price_cents: prices.get(&it.product_id).unwrap().price,
        })
        .collect();

    Ok((
        StatusCode::CREATED,
        Json(Order {
            id: order_id,
            customer_id: req.customer_id,
            status: "pending".to_string(),
            total_cents: total as i32,
            items,
        }),
    ))
}

async fn replay_order(
    pool: &PgPool,
    idem: Uuid,
) -> Result<(StatusCode, Json<Order>), (StatusCode, Json<serde_json::Value>)> {
    let row = sqlx::query(
        "SELECT id, customer_id, status::text, total_cents \
         FROM orders WHERE idempotency_key = $1",
    )
    .bind(idem)
    .fetch_optional(pool)
    .await
    .map_err(internal_error)?;

    let (id, customer_id, status, total_cents) = match row {
        Some(r) => (r.get("id"), r.get("customer_id"), r.get("status"), r.get("total_cents")),
        None => {
            return Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": "internal error"})),
            ));
        }
    };

    let item_rows = sqlx::query(
        "SELECT product_id, quantity, unit_price_cents FROM order_items WHERE order_id = $1",
    )
    .bind(id)
    .fetch_all(pool)
    .await
    .map_err(internal_error)?;

    let items = item_rows
        .iter()
        .map(|r| OrderItem {
            product_id: r.get("product_id"),
            quantity: r.get("quantity"),
            unit_price_cents: r.get("unit_price_cents"),
        })
        .collect();

    Ok((
        StatusCode::CREATED,
        Json(Order {
            id,
            customer_id,
            status,
            total_cents,
            items,
        }),
    ))
}

// ---------------------------------------------------------------------------
// /dashboard
// ---------------------------------------------------------------------------

const DASHBOARD_AGG: &str = "SELECT c.id, c.name, COUNT(o.id) AS order_count, \
    COALESCE(SUM(o.total_cents), 0)::bigint AS total_cents \
    FROM categories c \
    LEFT JOIN orders o ON o.status IN ('paid','shipped') \
        AND o.created_at >= now() - ($1::int || ' days')::interval \
        AND EXISTS (SELECT 1 FROM order_items oi JOIN products p ON p.id = oi.product_id \
            WHERE oi.order_id = o.id AND p.category_id = c.id) \
    GROUP BY c.id, c.name ORDER BY c.id";

pub async fn get_dashboard(
    State(state): State<AppState>,
    axum::extract::Query(params): axum::extract::Query<std::collections::HashMap<String, String>>,
) -> Result<impl axum::response::IntoResponse, (StatusCode, Json<serde_json::Value>)> {
    let days: i32 = params
        .get("days")
        .and_then(|v| v.parse().ok())
        .unwrap_or(30)
        .clamp(1, 365);

    let rows = sqlx::query(DASHBOARD_AGG)
        .bind(days)
        .fetch_all(&state.pool)
        .await
        .map_err(internal_error)?;

    let mut body = String::from(
        "<!doctype html><html><head><title>Bench dashboard</title></head><body>\
         <h1>Bench dashboard</h1><table border=1><thead><tr>\
         <th>Category</th><th>Orders</th><th>Total ($)</th></tr></thead><tbody>",
    );
    for r in &rows {
        let name: String = r.get("name");
        let order_count: i64 = r.get("order_count");
        let total_cents: i64 = r.get("total_cents");
        body.push_str(&format!(
            "<tr><td>{}</td><td>{}</td><td>{:.2}</td></tr>",
            html_escape(&name),
            order_count,
            total_cents as f64 / 100.0,
        ));
    }
    body.push_str("</tbody></table></body></html>");
    Ok((
        [(header::CONTENT_TYPE, "text/html; charset=utf-8")],
        axum::response::Html(body),
    ))
}

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
        .replace('"', "&quot;")
}

// ---------------------------------------------------------------------------
// /health, /metrics
// ---------------------------------------------------------------------------

pub async fn get_health() -> Json<serde_json::Value> {
    Json(serde_json::json!({"status": "ok"}))
}

pub async fn get_metrics() -> impl axum::response::IntoResponse {
    ([(header::CONTENT_TYPE, "text/plain; version=0.0.4")], metrics::render_metrics())
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

fn internal_error<E: std::fmt::Display>(
    e: E,
) -> (StatusCode, Json<serde_json::Value>) {
    tracing::error!("internal error: {}", e);
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(serde_json::json!({"error": "internal error"})),
    )
}
