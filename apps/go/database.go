// Database connection pool.
//
// The pool is built to the contract: exactly DB_POOL_SIZE connections, no
// more, no fewer. A framework that opens its own pool on top of the
// configured one would silently double the database's connection count, and
// the bench:db:active_connections recording rule would surface that as
// "over the configured pool size" -- and the trial would be discarded.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func newPool(ctx context.Context, cfg config) (*pgxpool.Pool, error) {
	pcfg, err := pgxpool.ParseConfig(cfg.DatabaseURL)
	if err != nil {
		return nil, fmt.Errorf("parse DATABASE_URL: %w", err)
	}

	// Honor the contract: the pool is exactly DB_POOL_SIZE connections.
	// MinConns is set to the same so the pool does not idle below its
	// configured size during warm-up.
	pcfg.MaxConns = cfg.DBPoolSize
	pcfg.MinConns = cfg.DBPoolSize

	// Timeouts. The contract requires the framework to time out a stuck
	// statement; the database also bounds its work. These are the values
	// that match the database's postgresql.conf.
	pcfg.MaxConnIdleTime = 5 * time.Minute
	pcfg.MaxConnLifetime = 30 * time.Minute
	pcfg.HealthCheckPeriod = 30 * time.Second

	// ConnectTimeout is short so a missing database fails the /health
	// check rather than the load test.
	startCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	pool, err := pgxpool.NewWithConfig(startCtx, pcfg)
	if err != nil {
		return nil, fmt.Errorf("create pool: %w", err)
	}

	// Wait for at least one connection to be available. pgxpool's New does
	// not block; the first request would otherwise be the first to discover
	// a misconfigured database.
	pingCtx, cancel2 := context.WithTimeout(ctx, 5*time.Second)
	defer cancel2()
	if err := pool.Ping(pingCtx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("ping database: %w", err)
	}

	slog.Info("pool initialized",
		"max_conns", pcfg.MaxConns,
		"min_conns", pcfg.MinConns,
		"max_conn_idle_time", pcfg.MaxConnIdleTime,
		"max_conn_lifetime", pcfg.MaxConnLifetime,
	)
	return pool, nil
}
