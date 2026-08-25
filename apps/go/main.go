// Package main is the Go + Gin reference implementation of the benchmark
// contract. It implements the four workloads + /health + /metrics against
// the contract in contracts/openapi.yaml.
//
// The implementation is intentionally boring. Every interesting choice is
// pushed to one of:
//
//   - database.go     the pgxpool setup, including the contract-mandated
//                      DB_POOL_SIZE enforcement
//   - handlers.go     the four workload handlers + /health + /metrics
//   - metrics.go      the Prometheus histogram with the names the
//                      recording rule in
//                      infra/observability/prometheus/rules/bench.yml
//                      reads from
//
// Things that are deliberately not in this implementation:
//
//   - Caching. The read workload hits PostgreSQL every time. A framework that
//     caches would look faster and lie about it; the contract forbids it
//     implicitly because the benchmark records per-request, not per-miss.
//   - Async I/O. pgx is already non-blocking under the hood; we are not
//     adding goroutine pools or actor frameworks on top.
//   - Dynamic configuration. The three environment variables the contract
//     requires (DATABASE_URL, DB_POOL_SIZE, LOG_LEVEL) are read at start and
//     held constant.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

func main() {
	slog.SetDefault(newLogger())

	if err := run(); err != nil {
		slog.Error("startup failed", "err", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	slog.Info("starting bench app",
		"framework", "go-gin",
		"db_pool_size", cfg.DBPoolSize,
		"port", cfg.Port,
		"log_level", cfg.LogLevel,
	)

	// Bring the database pool up before the HTTP server so /health reflects a
	// database-backed process. /health itself does not touch the database --
	// see handlers.go -- but the process can only claim "ready to serve" once
	// the pool has been initialized.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	pool, err := newPool(ctx, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()
	slog.Info("database pool ready")

	srv := newServer(cfg, pool)
	httpSrv := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           srv,
		ReadHeaderTimeout: 5 * time.Second,
		// Read/Write timeouts are deliberately long for benchmark traffic.
		// A framework that times out a 30s request is not meeting the
		// contract; the testbed never issues 30s requests.
	}

	// Serve in a goroutine so we can listen for the shutdown signal.
	errCh := make(chan error, 1)
	go func() {
		slog.Info("listening", "addr", httpSrv.Addr)
		if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
		slog.Info("shutdown signal received")
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return httpSrv.Shutdown(shutdownCtx)
}

type config struct {
	DatabaseURL string
	DBPoolSize  int32
	Port        string
	LogLevel    slog.Level
}

func loadConfig() (config, error) {
	c := config{
		DatabaseURL: os.Getenv("DATABASE_URL"),
		Port:        getenv("PORT", "8080"),
		LogLevel:    parseLogLevel(getenv("LOG_LEVEL", "warn")),
	}
	if c.DatabaseURL == "" {
		return c, errors.New("DATABASE_URL must be set")
	}
	poolSizeStr := getenv("DB_POOL_SIZE", "32")
	n, err := strconv.ParseInt(poolSizeStr, 10, 32)
	if err != nil {
		return c, errors.New("DB_POOL_SIZE must be an integer")
	}
	if n <= 0 {
		return c, errors.New("DB_POOL_SIZE must be > 0")
	}
	c.DBPoolSize = int32(n)
	return c, nil
}

func getenv(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func parseLogLevel(s string) slog.Level {
	switch s {
	case "error":
		return slog.LevelError
	case "warn", "warning":
		return slog.LevelWarn
	case "info":
		return slog.LevelInfo
	case "debug":
		return slog.LevelDebug
	default:
		return slog.LevelWarn
	}
}

func newLogger() *slog.Logger {
	// JSON output. The container's log driver parses it; a human reading
	// docker logs gets structured records instead of the default text
	// format's time prefix.
	return slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{
		Level: parseLogLevel(getenv("LOG_LEVEL", "warn")),
	}))
}
