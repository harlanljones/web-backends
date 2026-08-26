// Data-transfer and row models for the benchmark contract.
//
// Property names follow the benchmark's wire shape (snake_case). The API is
// serialized with a SnakeCase naming policy (see Program.cs), so a PascalCase
// property like `UnitPriceCents` is emitted as `unit_price_cents` and a
// request body containing `customer_id` is bound back to `CustomerId`.
//
// Dapper supplies the underscore-aware materializer (`MatchNamesWithUnderscores`),
// so a column `price_cents` maps to a property `PriceCents` and a column
// `unit_price_cents` maps to `UnitPriceCents`. Column types mirror the schema:
// `bigint` -> `long`, `integer` -> `int`, `text` -> `string`, `boolean` -> `bool`.

namespace Bench;

/// <summary>Static body of <c>GET /json</c>.</summary>
public class JsonResponse
{
    public string Service { get; set; } = "";
    public string Version { get; set; } = "";
    public string Time { get; set; } = "";
}

/// <summary>A product row from <c>GET /products/{id}</c>.</summary>
public class Product
{
    public long Id { get; set; }
    public string Sku { get; set; } = "";
    public string Name { get; set; } = "";
    public string Description { get; set; } = "";
    public int CategoryId { get; set; }
    public int PriceCents { get; set; }
    public int Stock { get; set; }
    public bool Active { get; set; }
}

/// <summary>A line item as supplied in an order request.</summary>
public class ItemRequest
{
    public long ProductId { get; set; }
    public int Quantity { get; set; }
}

/// <summary>The request body of <c>POST /orders</c>.</summary>
public class OrderRequest
{
    public long CustomerId { get; set; }
    public List<ItemRequest>? Items { get; set; }
}

/// <summary>A line item as returned in an order response.</summary>
public class OrderItem
{
    public long ProductId { get; set; }
    public int Quantity { get; set; }
    public int UnitPriceCents { get; set; }
}

/// <summary>The response body of <c>POST /orders</c> (created or replayed).</summary>
public class Order
{
    public long Id { get; set; }
    public long CustomerId { get; set; }
    public string Status { get; set; } = "";
    public long TotalCents { get; set; }
    public List<OrderItem> Items { get; set; } = new();
}

/// <summary>Row locked per product while writing an order (price + stock).</summary>
internal class PriceStock
{
    public int PriceCents { get; set; }
    public int Stock { get; set; }
}

/// <summary>Per-category aggregate row for the dashboard.</summary>
public class DashboardRow
{
    public int Id { get; set; }
    public string Name { get; set; } = "";
    public long OrderCount { get; set; }
    public long TotalCents { get; set; }
}

/// <summary>Body of <c>GET /health</c>.</summary>
public class HealthResponse
{
    public string Status { get; set; } = "";
}
