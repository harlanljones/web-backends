//! Configuration and logging setup.

use std::env;

pub struct Config {
    pub database_url: String,
    pub db_pool_size: u32,
    pub port: String,
    pub log_level: String,
}

impl Config {
    pub fn from_env() -> Result<Self, String> {
        let database_url = env::var("DATABASE_URL")
            .map_err(|_| "DATABASE_URL must be set".to_string())?;
        let db_pool_size: u32 = env::var("DB_POOL_SIZE")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(32);
        if db_pool_size == 0 {
            return Err("DB_POOL_SIZE must be > 0".to_string());
        }
        let port = env::var("PORT").unwrap_or_else(|_| "8080".to_string());
        let log_level = env::var("LOG_LEVEL").unwrap_or_else(|_| "warn".to_string());
        Ok(Self {
            database_url,
            db_pool_size,
            port,
            log_level,
        })
    }
}

/// Map the contract's LOG_LEVEL to a tracing filter expression.
/// The benchmark enforces log volume at WARN and above.
pub fn log_filter(level: &str) -> String {
    let lvl = match level {
        "error" => "error",
        "info" => "info",
        "debug" => "debug",
        _ => "warn",
    };
    format!("{lvl},sqlx=warn,hyper=warn,tower_http=warn,h2=warn")
}
