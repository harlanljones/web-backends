//! Database connection pool (sqlx).

use sqlx::postgres::{PgPool, PgPoolOptions};

use crate::config::Config;

/// Create a Postgres pool honoring the contract's DB_POOL_SIZE.
/// sqlx's pool max = DB_POOL_SIZE, min_connections = DB_POOL_SIZE so
/// the pool does not idle below its configured size during warm-up.
pub async fn make_pool(cfg: &Config) -> Result<PgPool, sqlx::Error> {
    PgPoolOptions::new()
        .max_connections(cfg.db_pool_size)
        .min_connections(cfg.db_pool_size)
        .acquire_timeout(std::time::Duration::from_secs(5))
        .connect(&cfg.database_url)
        .await
}
