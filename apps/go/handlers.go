// HTTP handlers for the four workloads + /health + /metrics.
//
// Each handler:
//
//  1. Reads the request
//  2. Calls the database (except /json, /health)
//  3. Returns the response with the right status code
//  4. Records the latency into the Prometheus histogram (handled by the
//     middleware, not by the handler itself)
//
// Errors are returned as a small JSON shape
// {"error": "...", "details": {...}}; the schema for that is in
// contracts/openapi.yaml under Error.
package main

import (
	"errors"
	"fmt"
	"html"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type app struct {
	cfg config
	pool *pgxpool.Pool
}

// ---------------------------------------------------------------------------
// /json
// ---------------------------------------------------------------------------

// jsonResponse is the static body of /json. A single source of truth so the
// every-trial and the conformance test see the same shape.
type jsonResponse struct {
	Service string `json:"service"`
	Version string `json:"version"`
	Time    string `json:"time"`
}

func (a *app) getJSON(c *gin.Context) {
	c.JSON(http.StatusOK, jsonResponse{
		Service: "bench",
		Version: "1.0.0",
		Time:    time.Now().UTC().Format(time.RFC3339Nano),
	})
}

// ---------------------------------------------------------------------------
// /products/{id}
// ---------------------------------------------------------------------------

type product struct {
	ID          int64  `json:"id"`
	SKU         string `json:"sku"`
	Name        string `json:"name"`
	Description string `json:"description"`
	CategoryID  int32  `json:"category_id"`
	PriceCents  int32  `json:"price_cents"`
	Stock       int32  `json:"stock"`
	Active      bool   `json:"active"`
}

const productSelect = `
SELECT id, sku, name, description, category_id, price_cents, stock, active
FROM products
WHERE id = $1
`

func (a *app) getProduct(c *gin.Context) {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid id"})
		return
	}

	var p product
	err = a.pool.QueryRow(c.Request.Context(), productSelect, id).Scan(
		&p.ID, &p.SKU, &p.Name, &p.Description, &p.CategoryID,
		&p.PriceCents, &p.Stock, &p.Active,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		c.JSON(http.StatusNotFound, gin.H{"error": "not found"})
		return
	}
	if err != nil {
		slog.Error("getProduct", "err", err, "id", id)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal error"})
		return
	}
	c.JSON(http.StatusOK, p)
}

// ---------------------------------------------------------------------------
// /orders
// ---------------------------------------------------------------------------

type orderItemRequest struct {
	ProductID int32 `json:"product_id" binding:"required"`
	Quantity  int32 `json:"quantity" binding:"required"`
}

type orderRequest struct {
	CustomerID int32             `json:"customer_id" binding:"required"`
	Items      []orderItemRequest `json:"items" binding:"required,dive"`
}

type orderItem struct {
	ProductID      int32 `json:"product_id"`
	Quantity       int32 `json:"quantity"`
	UnitPriceCents int32 `json:"unit_price_cents"`
}

type order struct {
	ID         int32       `json:"id"`
	CustomerID int32       `json:"customer_id"`
	Status     string      `json:"status"`
	TotalCents int32       `json:"total_cents"`
	Items      []orderItem `json:"items"`
}

// createOrder implements the transactional write workload.
//
// Three tables are touched in a single transaction: orders, order_items,
// inventory_ledger. Products.stock is decremented with a SELECT ... FOR UPDATE
// per item, so two concurrent requests for the same product cannot both
// succeed at the same stock level.
//
// Idempotency: a unique idempotency_key is inserted into orders. A retried
// request hits the unique constraint and we return the original row.
func (a *app) createOrder(c *gin.Context) {
	idemKey := c.GetHeader("Idempotency-Key")
	if idemKey == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "Idempotency-Key header is required"})
		return
	}

	var req orderRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid body", "details": gin.H{"reason": err.Error()}})
		return
	}
	if len(req.Items) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "items must be non-empty"})
		return
	}

	ctx := c.Request.Context()
	tx, err := a.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		slog.Error("begin tx", "err", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal error"})
		return
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	// Lock the product rows in id order. Locking in a stable order avoids
	// deadlocks when two concurrent requests touch overlapping product sets
	// in different orders.
	productIDs := make([]int32, 0, len(req.Items))
	seen := make(map[int32]struct{}, len(req.Items))
	for _, it := range req.Items {
		if _, ok := seen[it.ProductID]; ok {
			continue
		}
		seen[it.ProductID] = struct{}{}
		productIDs = append(productIDs, it.ProductID)
	}
	sortInt32(productIDs)

	type productRow struct {
		PriceCents int32
		Stock      int32
	}
	prices := make(map[int32]productRow, len(productIDs))
	for _, pid := range productIDs {
		var p productRow
		err := tx.QueryRow(ctx,
			"SELECT price_cents, stock FROM products WHERE id = $1 FOR UPDATE",
			pid,
		).Scan(&p.PriceCents, &p.Stock)
		if errors.Is(err, pgx.ErrNoRows) {
			c.JSON(http.StatusBadRequest, gin.H{"error": "unknown product", "details": gin.H{"product_id": pid}})
			return
		}
		if err != nil {
			slog.Error("lock product", "err", err, "product_id", pid)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "internal error"})
			return
		}
		prices[pid] = p
	}

	// Compute totals and check stock.
	var total int32
	for _, it := range req.Items {
		p, ok := prices[it.ProductID]
		if !ok {
			c.JSON(http.StatusBadRequest, gin.H{"error": "unknown product", "details": gin.H{"product_id": it.ProductID}})
			return
		}
		if p.Stock < it.Quantity {
			c.JSON(http.StatusConflict, gin.H{
				"error":   "insufficient stock",
				"details": gin.H{"product_id": it.ProductID, "available": p.Stock, "requested": it.Quantity},
			})
			return
		}
		total += p.PriceCents * it.Quantity
	}

	// Insert the order. A duplicate idempotency_key is the replay case.
	var orderID int32
	err = tx.QueryRow(ctx, `
		INSERT INTO orders (customer_id, status, total_cents, idempotency_key)
		VALUES ($1, 'pending', $2, $3)
		ON CONFLICT (idempotency_key) DO NOTHING
		RETURNING id
	`, req.CustomerID, total, idemKey).Scan(&orderID)
	if errors.Is(err, pgx.ErrNoRows) {
		// Replay. The transaction is still open so we have to rollback --
		// a no-op rollback, but explicit.
		if err := tx.Rollback(ctx); err != nil {
			slog.Error("replay rollback", "err", err)
		}
		a.returnExistingOrder(c, idemKey)
		return
	}
	if err != nil {
		slog.Error("insert order", "err", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal error"})
		return
	}

	// Insert items + ledger + decrement stock. The product rows are already
	// locked, so the decrement is safe.
	for _, it := range req.Items {
		p := prices[it.ProductID]
		_, err := tx.Exec(ctx, `
			INSERT INTO order_items (order_id, product_id, quantity, unit_price_cents)
			VALUES ($1, $2, $3, $4)
		`, orderID, it.ProductID, it.Quantity, p.PriceCents)
		if err != nil {
			slog.Error("insert order_item", "err", err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "internal error"})
			return
		}
		_, err = tx.Exec(ctx, `
			INSERT INTO inventory_ledger (product_id, order_id, delta)
			VALUES ($1, $2, $3)
		`, it.ProductID, orderID, -it.Quantity)
		if err != nil {
			slog.Error("insert ledger", "err", err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "internal error"})
			return
		}
		_, err = tx.Exec(ctx,
			"UPDATE products SET stock = stock - $1, updated_at = now() WHERE id = $2",
			it.Quantity, it.ProductID,
		)
		if err != nil {
			slog.Error("decrement stock", "err", err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "internal error"})
			return
		}
	}

	if err := tx.Commit(ctx); err != nil {
		slog.Error("commit", "err", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal error"})
		return
	}

	// Replay-safe response: read the committed rows and return them.
	items := make([]orderItem, 0, len(req.Items))
	for _, it := range req.Items {
		items = append(items, orderItem{
			ProductID:      it.ProductID,
			Quantity:       it.Quantity,
			UnitPriceCents: prices[it.ProductID].PriceCents,
		})
	}
	c.JSON(http.StatusCreated, order{
		ID:         orderID,
		CustomerID: req.CustomerID,
		Status:     "pending",
		TotalCents: total,
		Items:      items,
	})
}

func (a *app) returnExistingOrder(c *gin.Context, idemKey string) {
	ctx := c.Request.Context()
	var (
		o          order
		createdAt  time.Time
	)
	err := a.pool.QueryRow(ctx, `
		SELECT id, customer_id, status::text, total_cents, created_at
		FROM orders WHERE idempotency_key = $1
	`, idemKey).Scan(&o.ID, &o.CustomerID, &o.Status, &o.TotalCents, &createdAt)
	if err != nil {
		slog.Error("read replay order", "err", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal error"})
		return
	}

	rows, err := a.pool.Query(ctx, `
		SELECT product_id, quantity, unit_price_cents
		FROM order_items WHERE order_id = $1
	`, o.ID)
	if err != nil {
		slog.Error("read replay items", "err", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal error"})
		return
	}
	defer rows.Close()
	for rows.Next() {
		var it orderItem
		if err := rows.Scan(&it.ProductID, &it.Quantity, &it.UnitPriceCents); err != nil {
			slog.Error("scan item", "err", err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "internal error"})
			return
		}
		o.Items = append(o.Items, it)
	}
	if err := rows.Err(); err != nil {
		slog.Error("rows err", "err", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal error"})
		return
	}
	c.JSON(http.StatusCreated, o)
}

// ---------------------------------------------------------------------------
// /dashboard
// ---------------------------------------------------------------------------

// dashboardRow is the per-category aggregate the dashboard renders.
type dashboardRow struct {
	CategoryID   int32
	CategoryName string
	OrderCount   int64
	TotalCents   int64
}

const dashboardAggregate = `
SELECT
  c.id,
  c.name,
  COUNT(o.id)         AS order_count,
  COALESCE(SUM(o.total_cents), 0)::bigint AS total_cents
FROM categories c
LEFT JOIN orders o
  ON o.status IN ('paid', 'shipped')
  AND o.created_at >= now() - ($1::int || ' days')::interval
  AND EXISTS (
    SELECT 1 FROM order_items oi
    JOIN products p ON p.id = oi.product_id
    WHERE oi.order_id = o.id AND p.category_id = c.id
  )
GROUP BY c.id, c.name
ORDER BY c.id
`

func (a *app) getDashboard(c *gin.Context) {
	days := 30
	if v := c.Query("days"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > 365 {
			c.JSON(http.StatusBadRequest, gin.H{"error": "days must be 1..365"})
			return
		}
		days = n
	}

	rows, err := a.pool.Query(c.Request.Context(), dashboardAggregate, days)
	if err != nil {
		slog.Error("dashboard aggregate", "err", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal error"})
		return
	}
	defer rows.Close()

	var results []dashboardRow
	for rows.Next() {
		var r dashboardRow
		if err := rows.Scan(&r.CategoryID, &r.CategoryName, &r.OrderCount, &r.TotalCents); err != nil {
			slog.Error("scan dashboard", "err", err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "internal error"})
			return
		}
		results = append(results, r)
	}
	if err := rows.Err(); err != nil {
		slog.Error("rows err", "err", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal error"})
		return
	}

	c.Header("Content-Type", "text/html; charset=utf-8")
	var b []byte
	b = append(b, "<!doctype html><html><head><title>Bench dashboard</title></head><body>"...)
	b = append(b, "<h1>Bench dashboard</h1>"...)
	b = append(b, "<table border=1><thead><tr><th>Category</th><th>Orders</th><th>Total ($)</th></tr></thead><tbody>"...)
	for _, r := range results {
		b = append(b, fmt.Sprintf("<tr><td>%s</td><td>%d</td><td>%.2f</td></tr>",
			html.EscapeString(r.CategoryName), r.OrderCount, float64(r.TotalCents)/100.0)...)
	}
	b = append(b, "</tbody></table></body></html>"...)
	c.String(http.StatusOK, "%s", b)
}

// ---------------------------------------------------------------------------
// /health, /metrics, middleware
// ---------------------------------------------------------------------------

func (a *app) getHealth(c *gin.Context) {
	// Per the contract, /health must not require a database round trip. The
	// process being up and listening is the signal. The pool is initialized
	// at startup (see main.go), so by the time we serve HTTP, the pool is
	// usable.
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func middlewareMetrics() gin.HandlerFunc {
	return func(c *gin.Context) {
		start := time.Now()
		c.Next()
		// Use the route's full path template, not the request's URL. That
		// gives the four workload names as labels, not a per-id label set
		// that would explode Prometheus.
		path := workloadName(c.FullPath())
		httpRequestDuration.WithLabelValues(path, c.Request.Method, strconv.Itoa(c.Writer.Status())).
			Observe(time.Since(start).Seconds())
	}
}

// newServer wires the routes, the metrics middleware, and gin in release
// mode. Release mode silences gin's per-request log output, which would
// otherwise dominate the framework's log budget at 10k RPS.
func newServer(cfg config, pool *pgxpool.Pool) http.Handler {
	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Recovery())
	r.Use(middlewareMetrics())

	a := &app{cfg: cfg, pool: pool}

	r.GET("/json", a.getJSON)
	r.GET("/products/:id", a.getProduct)
	r.POST("/orders", a.createOrder)
	r.GET("/dashboard", a.getDashboard)
	r.GET("/health", a.getHealth)

	// /metrics is the Prometheus text format from the standard client.
	// promhttp.Handler is the canonical handler; the path can be anything
	// but the contract fixes it at /metrics.
	r.GET("/metrics", gin.WrapH(promhttp.Handler()))
	return r
}

// sortInt32 is a tiny insertion sort. n is at most 20 (the API contract
// caps it), so the O(n^2) is irrelevant and avoiding the sort package
// keeps the imports list short.
func sortInt32(s []int32) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j-1] > s[j]; j-- {
			s[j-1], s[j] = s[j], s[j-1]
		}
	}
}
