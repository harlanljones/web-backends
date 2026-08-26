// ASP.NET Core (minimal API) implementation of the benchmark contract,
// mirroring apps/go/handlers.go and apps/rust/src/handlers.rs.
//
// Data access is Dapper over Npgsql (no EF Core): the benchmark measures the
// framework, not an ORM. The connection pool is a single `NpgsqlDataSource`
// sized exactly DB_POOL_SIZE, so the database sees no second pool on top of
// the configured one.
//
// The metrics histogram is a custom `Histogram` named
// `http_request_duration_seconds` with labels {path,method,status}. It is
// recorded from a middleware, not from prometheus-net's `UseHttpMetrics()`,
// because the default histogram is labelled {code,method,controller,action,route}
// and would not emit the contracted `path/method/status` label set.

using System.Diagnostics;
using System.Net;
using System.Text;
using System.Text.Json;
using Dapper;
using Microsoft.AspNetCore.Mvc;
using Npgsql;
using Prometheus;

namespace Bench;

public class Program
{
    // ------------------------------------------------------------------ //
    // Static SQL. Shaped to match the reference implementations exactly.
    // ------------------------------------------------------------------ //

    private const string ProductSelect = @"
        SELECT id, sku, name, description, category_id, price_cents, stock, active
        FROM products
        WHERE id = @id";

    private const string LockProductSql = @"
        SELECT price_cents, stock FROM products WHERE id = @id FOR UPDATE";

    private const string InsertOrderSql = @"
        INSERT INTO orders (customer_id, status, total_cents, idempotency_key)
        VALUES (@c, 'pending', @t::int, @k)
        ON CONFLICT (idempotency_key) DO NOTHING
        RETURNING id";

    private const string InsertItemSql = @"
        INSERT INTO order_items (order_id, product_id, quantity, unit_price_cents)
        VALUES (@order_id, @product_id, @quantity, @unit_price_cents)";

    private const string InsertLedgerSql = @"
        INSERT INTO inventory_ledger (product_id, order_id, delta)
        VALUES (@product_id, @order_id, @delta)";

    private const string DecrementStockSql = @"
        UPDATE products SET stock = stock - @q, updated_at = now() WHERE id = @id";

    private const string ReplayOrderSql = @"
        SELECT id, customer_id, status::text AS status, total_cents
        FROM orders WHERE idempotency_key = @k";

    private const string ReplayItemsSql = @"
        SELECT product_id, quantity, unit_price_cents
        FROM order_items WHERE order_id = @order_id";

    private const string DashboardSql = @"
        SELECT c.id, c.name, COUNT(o.id) AS order_count,
               COALESCE(SUM(o.total_cents), 0)::bigint AS total_cents
        FROM categories c
        LEFT JOIN orders o
          ON o.status IN ('paid', 'shipped')
          AND o.created_at >= now() - (@days::int || ' days')::interval
          AND EXISTS (
              SELECT 1 FROM order_items oi
              JOIN products p ON p.id = oi.product_id
              WHERE oi.order_id = o.id AND p.category_id = c.id
          )
        GROUP BY c.id, c.name
        ORDER BY c.id";

    // ------------------------------------------------------------------ //
    // Metrics
    // ------------------------------------------------------------------ //

    private static readonly Histogram _httpRequestDuration = Metrics.CreateHistogram(
        "http_request_duration_seconds",
        "End-to-end request latency in seconds.",
        new HistogramConfiguration
        {
            LabelNames = new[] { "path", "method", "status" },
            Buckets = new[] { 0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5 },
        });

    /// <summary>The workload name label for a matched route (mirrors the Go/Rust mapping).</summary>
    /// <summary>The workload name label for a request (mirrors the Go/Rust
    /// mapping). Derived from the request path rather than the matched route:
    /// the metrics middleware runs before the endpoint is resolved, so the
    /// path is the only reliable signal. The parameterized product route maps
    /// to <c>product_read</c> regardless of the id.</summary>
    private static string WorkloadName(HttpContext ctx)
    {
        var path = ctx.Request.Path.Value ?? "";
        if (path.StartsWith("/json", StringComparison.OrdinalIgnoreCase)) return "json";
        if (path.StartsWith("/products/", StringComparison.OrdinalIgnoreCase)) return "product_read";
        if (path.StartsWith("/orders", StringComparison.OrdinalIgnoreCase)) return "order_write";
        if (path.StartsWith("/dashboard", StringComparison.OrdinalIgnoreCase)) return "dashboard";
        if (path.StartsWith("/health", StringComparison.OrdinalIgnoreCase)) return "infra";
        if (path.StartsWith("/metrics", StringComparison.OrdinalIgnoreCase)) return "infra";
        return "other";
    }

    // ------------------------------------------------------------------ //
    // Startup
    // ------------------------------------------------------------------ //

    public static void Main(string[] args)
    {
        // Map snake_case columns to PascalCase properties for every Dapper
        // query, matching the reference implementations' column naming.
        DefaultTypeMap.MatchNamesWithUnderscores = true;

        var builder = WebApplication.CreateBuilder(args);

        builder.Logging.ClearProviders();
        builder.Logging.AddConsole();
        builder.Logging.SetMinimumLevel(ParseLogLevel(Env("LOG_LEVEL", "warn")));

        // Snake_case on the wire, so Product.Sku -> "sku", Order.TotalCents ->
        // "total_cents", and the request body's "customer_id" binds to CustomerId.
        builder.Services.ConfigureHttpJsonOptions(o =>
        {
            o.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower;
            o.SerializerOptions.PropertyNameCaseInsensitive = true;
        });

        // The library DATABASE_URL is libpq-form; Npgsql wants its own
        // connection string. Parse it and size the pool to exactly DB_POOL_SIZE.
        var databaseUrl = Env("DATABASE_URL", "");
        if (string.IsNullOrEmpty(databaseUrl))
        {
            throw new InvalidOperationException("DATABASE_URL must be set");
        }
        var poolSize = ParsePoolSize(Env("DB_POOL_SIZE", "32"));
        var connectionString = BuildNpgsqlConnectionString(databaseUrl, poolSize);

        builder.Services.AddSingleton(NpgsqlDataSource.Create(connectionString));

        var port = Env("PORT", "8080");
        builder.WebHost.UseUrls("http://0.0.0.0:" + port);

        var app = builder.Build();

        app.Use(async (ctx, next) =>
        {
            var sw = Stopwatch.StartNew();
            try
            {
                await next();
            }
            catch
            {
                _httpRequestDuration
                    .WithLabels(WorkloadName(ctx), ctx.Request.Method, "500")
                    .Observe(sw.Elapsed.TotalSeconds);
                throw;
            }

            _httpRequestDuration
                .WithLabels(WorkloadName(ctx), ctx.Request.Method, ctx.Response.StatusCode.ToString())
                .Observe(sw.Elapsed.TotalSeconds);
        });

        // GET /json ----------------------------------------------------- //
        app.MapGet("/json", () => Results.Json(new JsonResponse
        {
            Service = "bench",
            Version = "1.0.0",
            Time = DateTime.UtcNow.ToString("o"),
        }));

        // GET /products/{id} ------------------------------------------- //
        app.MapGet("/products/{id}", async (long id, [FromServices] NpgsqlDataSource db) =>
        {
            await using var conn = await db.OpenConnectionAsync();
            var product = await conn.QuerySingleOrDefaultAsync<Product>(ProductSelect, new { id });
            if (product is null)
            {
                return Results.Json(new { error = "not found" }, statusCode: StatusCodes.Status404NotFound);
            }
            return Results.Json(product);
        });

        // POST /orders -------------------------------------------------- //
        app.MapPost("/orders", async Task<IResult> (
            [FromHeader(Name = "Idempotency-Key")] string? idemKey,
            [FromBody] OrderRequest req,
            [FromServices] NpgsqlDataSource db) =>
        {
            if (string.IsNullOrEmpty(idemKey))
            {
                return Results.Json(
                    new { error = "Idempotency-Key header is required" },
                    statusCode: StatusCodes.Status400BadRequest);
            }
            if (!Guid.TryParse(idemKey, out var idemGuid))
            {
                return Results.Json(
                    new { error = "invalid Idempotency-Key" },
                    statusCode: StatusCodes.Status400BadRequest);
            }
            if (req.Items is null || req.Items.Count == 0)
            {
                return Results.Json(
                    new { error = "items must be non-empty" },
                    statusCode: StatusCodes.Status400BadRequest);
            }

            var productIds = req.Items.Select(i => i.ProductId).Distinct().OrderBy(x => x).ToList();

            await using var conn = await db.OpenConnectionAsync();
            await using var tx = await conn.BeginTransactionAsync();

            var prices = new Dictionary<long, PriceStock>(productIds.Count);
            foreach (var pid in productIds)
            {
                var row = await conn.QuerySingleOrDefaultAsync<PriceStock>(LockProductSql, new { id = pid }, tx);
                if (row is null)
                {
                    await tx.RollbackAsync();
                    return Results.Json(
                        new { error = "unknown product", details = new { product_id = pid } },
                        statusCode: StatusCodes.Status400BadRequest);
                }
                prices[pid] = row;
            }

            long total = 0;
            foreach (var item in req.Items)
            {
                var p = prices[item.ProductId];
                if (p.Stock < item.Quantity)
                {
                    await tx.RollbackAsync();
                    return Results.Json(new
                    {
                        error = "insufficient stock",
                        details = new { product_id = item.ProductId, available = p.Stock, requested = item.Quantity },
                    }, statusCode: StatusCodes.Status409Conflict);
                }
                total += (long)p.PriceCents * item.Quantity;
            }

            var orderId = await conn.QuerySingleOrDefaultAsync<long?>(
                InsertOrderSql, new { c = req.CustomerId, t = total, k = idemGuid }, tx);

            if (orderId is null)
            {
                await tx.RollbackAsync();
                return await ReplayOrderAsync(conn, idemGuid);
            }

            foreach (var item in req.Items)
            {
                var p = prices[item.ProductId];
                await conn.ExecuteAsync(InsertItemSql,
                    new { order_id = orderId.Value, product_id = item.ProductId, quantity = item.Quantity, unit_price_cents = p.PriceCents }, tx);
                await conn.ExecuteAsync(InsertLedgerSql,
                    new { product_id = item.ProductId, order_id = orderId.Value, delta = -item.Quantity }, tx);
                await conn.ExecuteAsync(DecrementStockSql,
                    new { q = item.Quantity, id = item.ProductId }, tx);
            }

            await tx.CommitAsync();

            var response = new Order
            {
                Id = orderId.Value,
                CustomerId = req.CustomerId,
                Status = "pending",
                TotalCents = total,
                Items = req.Items.Select(i => new OrderItem
                {
                    ProductId = i.ProductId,
                    Quantity = i.Quantity,
                    UnitPriceCents = prices[i.ProductId].PriceCents,
                }).ToList(),
            };
            return Results.Json(response, statusCode: StatusCodes.Status201Created);
        });

        // GET /dashboard -------------------------------------------------- //
        app.MapGet("/dashboard", async (int? days, [FromServices] NpgsqlDataSource db) =>
        {
            var d = Math.Clamp(days ?? 30, 1, 365);

            await using var conn = await db.OpenConnectionAsync();
            var rows = (await conn.QueryAsync<DashboardRow>(DashboardSql, new { days = d })).ToList();

            var body = new StringBuilder();
            body.Append("<!doctype html><html><head><title>Bench dashboard</title></head><body>");
            body.Append("<h1>Bench dashboard</h1>");
            body.Append("<table border=1><thead><tr><th>Category</th><th>Orders</th><th>Total ($)</th></tr></thead><tbody>");
            foreach (var r in rows)
            {
                body.Append($"<tr><td>{WebUtility.HtmlEncode(r.Name)}</td><td>{r.OrderCount}</td><td>{(r.TotalCents / 100.0):F2}</td></tr>");
            }
            body.Append("</tbody></table></body></html>");

            return Results.Content(body.ToString(), "text/html; charset=utf-8");
        });

        // GET /health ---------------------------------------------------- //
        app.MapGet("/health", () => Results.Json(new HealthResponse { Status = "ok" }));

        // GET /metrics --------------------------------------------------- //
        app.MapGet("/metrics", async (HttpContext ctx) =>
        {
            ctx.Response.ContentType = "text/plain; version=0.0.4; charset=utf-8";
            await Metrics.DefaultRegistry.CollectAndExportAsTextAsync(ctx.Response.Body);
        });

        app.Run();
    }

    /// <summary>Replay read: fetch an existing order plus its items under a
    /// repeated Idempotency-Key and return it as 201.</summary>
    private static async Task<IResult> ReplayOrderAsync(NpgsqlConnection conn, Guid idemGuid)
    {
        var order = await conn.QuerySingleOrDefaultAsync<Order>(ReplayOrderSql, new { k = idemGuid });
        if (order is null)
        {
            return Results.Json(new { error = "internal error" }, statusCode: StatusCodes.Status500InternalServerError);
        }
        order.Items = (await conn.QueryAsync<OrderItem>(ReplayItemsSql, new { order_id = order.Id })).ToList();
        return Results.Json(order, statusCode: StatusCodes.Status201Created);
    }

    // ------------------------------------------------------------------ //
    // Config helpers
    // ------------------------------------------------------------------ //

    private static string Env(string key, string fallback) =>
        Environment.GetEnvironmentVariable(key) is { Length: > 0 } v ? v : fallback;

    private static LogLevel ParseLogLevel(string s) => s.ToLowerInvariant() switch
    {
        "error" or "critical" => LogLevel.Error,
        "warning" or "warn" => LogLevel.Warning,
        "info" => LogLevel.Information,
        "debug" or "trace" => LogLevel.Debug,
        _ => LogLevel.Warning,
    };

    private static int ParsePoolSize(string s)
    {
        if (!int.TryParse(s, out var n) || n <= 0)
        {
            throw new InvalidOperationException("DB_POOL_SIZE must be a positive integer");
        }
        return n;
    }

    /// <summary>Convert a libpq-style <c>postgres://user:pass@host:port/db</c>
    /// URL into an Npgsql connection string, honoring DB_POOL_SIZE. Npgsql does
    /// not parse libpq URLs, so the components are extracted and rebuilt.</summary>
    private static string BuildNpgsqlConnectionString(string url, int poolSize)
    {
        var builder = new NpgsqlConnectionStringBuilder();

        if (!url.StartsWith("postgres://", StringComparison.OrdinalIgnoreCase) &&
            !url.StartsWith("postgresql://", StringComparison.OrdinalIgnoreCase))
        {
            // Already an Npgsql-style string; just size the pool.
            builder.ConnectionString = url;
            builder.MaxPoolSize = poolSize;
            builder.MinPoolSize = poolSize;
            return builder.ConnectionString;
        }

        var rest = url[(url.IndexOf("://", StringComparison.Ordinal) + 3)..];

        var queryIdx = rest.IndexOf('?');
        var withoutQuery = queryIdx >= 0 ? rest[..queryIdx] : rest;

        var slashIdx = withoutQuery.IndexOf('/');
        var authority = slashIdx >= 0 ? withoutQuery[..slashIdx] : withoutQuery;
        var database = slashIdx >= 0 ? withoutQuery[(slashIdx + 1)..] : "";
        database = Uri.UnescapeDataString(database);

        var atIdx = authority.LastIndexOf('@');
        var userInfo = atIdx >= 0 ? authority[..atIdx] : "";
        var hostPort = atIdx >= 0 ? authority[(atIdx + 1)..] : authority;

        var colonIdx = userInfo.IndexOf(':');
        var user = colonIdx >= 0 ? userInfo[..colonIdx] : userInfo;
        var password = colonIdx >= 0 ? userInfo[(colonIdx + 1)..] : "";

        var host = hostPort;
        var port = 5432;
        var lastColon = hostPort.LastIndexOf(':');
        if (lastColon >= 0)
        {
            host = hostPort[..lastColon];
            port = int.TryParse(hostPort[(lastColon + 1)..], out var p) ? p : 5432;
        }

        builder.Host = Uri.UnescapeDataString(host);
        builder.Port = port;
        builder.Database = database;
        builder.Username = Uri.UnescapeDataString(user);
        builder.Password = Uri.UnescapeDataString(password);
        builder.MaxPoolSize = poolSize;
        builder.MinPoolSize = poolSize;

        return builder.ConnectionString;
    }
}
