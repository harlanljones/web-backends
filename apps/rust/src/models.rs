//! Domain model types shared across handlers.

use serde::{Deserialize, Serialize};

/// Static body of /json.
#[derive(Serialize)]
pub struct JsonResponse {
    pub service: &'static str,
    pub version: &'static str,
    pub time: String,
}

/// Product as returned by /products/{id}.
#[derive(Serialize)]
pub struct Product {
    pub id: i64,
    pub sku: String,
    pub name: String,
    pub description: String,
    pub category_id: i32,
    pub price_cents: i32,
    pub stock: i32,
    pub active: bool,
}

#[derive(Deserialize)]
pub struct OrderRequest {
    pub customer_id: i64,
    pub items: Vec<OrderItemRequest>,
}

#[derive(Deserialize)]
pub struct OrderItemRequest {
    pub product_id: i64,
    pub quantity: i32,
}

#[derive(Serialize)]
pub struct OrderItem {
    pub product_id: i64,
    pub quantity: i32,
    pub unit_price_cents: i32,
}

#[derive(Serialize)]
pub struct Order {
    pub id: i64,
    pub customer_id: i64,
    pub status: String,
    pub total_cents: i32,
    pub items: Vec<OrderItem>,
}
