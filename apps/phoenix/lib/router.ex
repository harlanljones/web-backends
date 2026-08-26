defmodule Bench.Router do
  @moduledoc """
  Plug.Router implementing the benchmark contract.

  Six routes: /json, /products/:id, /orders, /dashboard, /health,
  /metrics. Uses a single Postgrex pool (started by Bench.Application).

  Deliberately not done: no caching, no ORM (Postgrex directly), no
  per-request logging. The BEAM process-per-request model is the
  framework's concurrency story.
  """

  use Plug.Router
  require Logger

  @pool :bench_pg

  # Metrics middleware wraps the whole pipeline so it can measure the
  # time spent in the route handler.
  plug :metrics_middleware
  plug :match
  plug :dispatch

  import Plug.Conn

  # ---------------------------------------------------------------------------
  # /json
  # ---------------------------------------------------------------------------
  get "/json" do
    send_json(conn, 200, %{
      service: "bench",
      version: "1.0.0",
      time: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  # ---------------------------------------------------------------------------
  # /products/:id
  # ---------------------------------------------------------------------------
  get "/products/:id" do
    with {id, ""} <- Integer.parse(id),
         {:ok, row} <- Postgrex.query(@pool, product_sql(), [id]),
         [row | _] <- row.rows do
      send_json(conn, 200, product_map(row))
    else
      _ -> send_json(conn, 404, %{error: "not found"})
    end
  end

  # ---------------------------------------------------------------------------
  # /orders
  # ---------------------------------------------------------------------------
  post "/orders" do
    {:ok, body, _} = Plug.Conn.read_body(conn)
    idem_key = Plug.Conn.get_req_header(conn, "idempotency-key") |> List.first()

    if is_nil(idem_key) or idem_key == "" do
      send_json(conn, 400, %{error: "Idempotency-Key header is required"})
    else
      case Jason.decode(body) do
        {:ok, %{"customer_id" => customer_id, "items" => items}} when is_list(items) and items != [] ->
          create_order(conn, customer_id, items, idem_key)

        {:ok, _} ->
          send_json(conn, 400, %{error: "invalid body"})

        {:error, _} ->
          send_json(conn, 400, %{error: "invalid body"})
      end
    end
  end

  defp create_order(conn, customer_id, items, idem_key) do
    product_ids =
      items
      |> Enum.map(& &1["product_id"])
      |> Enum.uniq()
      |> Enum.sort()

    # Wrap the multi-statement write in a single Postgrex transaction.
    result =
      Postgrex.transaction(@pool, fn tx ->
        # Lock products in sorted id order; collect price + stock.
        prices =
          Enum.reduce_while(product_ids, {:ok, %{}}, fn pid, {:ok, acc} ->
            case Postgrex.query(tx, "SELECT price_cents, stock FROM products WHERE id = $1 FOR UPDATE", [pid]) do
              {:ok, %{rows: [[price, stock] | _]}} -> {:cont, {:ok, Map.put(acc, pid, {price, stock})}}
              _ -> {:halt, {:error, {:unknown_product, pid}}}
            end
          end)

        with {:ok, prices_map} <- prices,
             {:ok, _} <- check_stock(items, prices_map),
             {:ok, total} <- compute_total(items, prices_map),
             {:ok, order_id} <- insert_order(tx, customer_id, total, idem_key) do
          if is_nil(order_id) do
            # Replay: the idempotency key already exists; no items to insert.
            {:ok, %{prices: prices_map, total: total, order_id: nil}}
          else
            case insert_order_items(tx, order_id, items, prices_map) do
              {:ok, :ok} -> {:ok, %{prices: prices_map, total: total, order_id: order_id}}
              {:error, e} -> {:error, e}
            end
          end
        end
      end)

    case result do
      # The transaction wraps our map: {:ok, {:ok, %{...}}}.
      {:ok, {:ok, %{order_id: nil}}} ->
        # Replay: read the original order + items by idempotency key.
        replay_order(conn, idem_key)

      {:ok, {:ok, %{order_id: order_id, prices: prices_map, total: total}}} ->
        items_resp = Enum.map(items, fn it ->
          {price, _stock} = Map.fetch!(prices_map, it["product_id"])
          %{product_id: it["product_id"], quantity: it["quantity"], unit_price_cents: price}
        end)
        send_json(conn, 201, %{
          id: order_id,
          customer_id: customer_id,
          status: "pending",
          total_cents: total,
          items: items_resp
        })

      {:error, {:unknown_product, pid}} ->
        send_json(conn, 400, %{error: "unknown product", product_id: pid})

      {:error, {:insufficient, pid, available, requested}} ->
        send_json(conn, 409, %{error: "insufficient stock", product_id: pid, available: available, requested: requested})

      {:error, other} ->
        Logger.error("order tx failed: #{inspect(other)}")
        send_json(conn, 500, %{error: "internal error"})
    end
  end

  defp check_stock(items, prices) do
    Enum.reduce_while(items, {:ok, nil}, fn it, {:ok, _} ->
      {_price, stock} = Map.fetch!(prices, it["product_id"])
      if stock >= it["quantity"] do
        {:cont, {:ok, nil}}
      else
        {:halt, {:error, {:insufficient, it["product_id"], stock, it["quantity"]}}}
      end
    end)
  end

  defp compute_total(items, prices) do
    total = Enum.reduce(items, 0, fn it, acc ->
      {price, _stock} = Map.fetch!(prices, it["product_id"])
      acc + price * it["quantity"]
    end)
    {:ok, total}
  end

  defp insert_order(tx, customer_id, total, idem_key) do
    # idempotency_key is uuid; cast the text param. DO NOTHING on conflict.
    sql = """
    INSERT INTO orders (customer_id, status, total_cents, idempotency_key)
    VALUES ($1, 'pending', $2, $3::uuid)
    ON CONFLICT (idempotency_key) DO NOTHING
    RETURNING id
    """
    case Postgrex.query(tx, sql, [customer_id, total, uuid_binary(idem_key)]) do
      {:ok, %{rows: [[id | _] | _]}} -> {:ok, id}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, e} -> {:error, e}
    end
  end

  defp insert_order_items(tx, order_id, items, prices) do
    result =
      Enum.reduce_while(items, :ok, fn it, :ok ->
        {price, _stock} = Map.fetch!(prices, it["product_id"])
        case Postgrex.query(tx, "INSERT INTO order_items (order_id, product_id, quantity, unit_price_cents) VALUES ($1, $2, $3, $4)", [order_id, it["product_id"], it["quantity"], price]) do
          {:ok, _} ->
            case Postgrex.query(tx, "INSERT INTO inventory_ledger (product_id, order_id, delta) VALUES ($1, $2, $3)", [it["product_id"], order_id, -it["quantity"]]) do
              {:ok, _} ->
                case Postgrex.query(tx, "UPDATE products SET stock = stock - $1, updated_at = now() WHERE id = $2", [it["quantity"], it["product_id"]]) do
                  {:ok, _} -> {:cont, :ok}
                  {:error, e} -> {:halt, {:error, e}}
                end
              {:error, e} -> {:halt, {:error, e}}
            end
          {:error, e} -> {:halt, {:error, e}}
        end
      end)
    {:ok, result}
  end

  defp replay_order(conn, idem_key) do
    with {:ok, %{rows: [[id, customer_id, status, total | _] | _]}} <-
           Postgrex.query(@pool, "SELECT id, customer_id, status::text, total_cents FROM orders WHERE idempotency_key = $1::uuid", [uuid_binary(idem_key)]),
         {:ok, %{rows: item_rows}} <-
           Postgrex.query(@pool, "SELECT product_id, quantity, unit_price_cents FROM order_items WHERE order_id = $1", [id]) do
      items = Enum.map(item_rows, fn [product_id, quantity, unit_price_cents] ->
        %{product_id: product_id, quantity: quantity, unit_price_cents: unit_price_cents}
      end)
      send_json(conn, 201, %{id: id, customer_id: customer_id, status: status, total_cents: total, items: items})
    else
      _ -> send_json(conn, 500, %{error: "internal error"})
    end
  end

  # ---------------------------------------------------------------------------
  # /dashboard
  # ---------------------------------------------------------------------------
  get "/dashboard" do
    conn = fetch_query_params(conn)
    days =
      case conn.query_params["days"] do
        nil -> 30
        d -> (String.to_integer(d) |> then(&Kernel.max(1, Kernel.min(&1, 365))))
      end

    sql = """
    SELECT c.id, c.name, COUNT(o.id) AS order_count,
      COALESCE(SUM(o.total_cents), 0)::bigint AS total_cents
    FROM categories c
    LEFT JOIN orders o
      ON o.status IN ('paid', 'shipped')
      AND o.created_at >= now() - ($1::int || ' days')::interval
      AND EXISTS (SELECT 1 FROM order_items oi JOIN products p ON p.id = oi.product_id
        WHERE oi.order_id = o.id AND p.category_id = c.id)
    GROUP BY c.id, c.name ORDER BY c.id
    """

    body =
      case Postgrex.query(@pool, sql, [days]) do
        {:ok, %{rows: rows}} ->
          trs =
            Enum.map(rows, fn [_id, name, order_count, total_cents] ->
              "<tr><td>#{html_escape(name)}</td><td>#{order_count}</td><td>#{Float.round(total_cents / 100, 2)}</td></tr>"
            end)
          "<!doctype html><html><head><title>Bench dashboard</title></head><body><h1>Bench dashboard</h1><table border=1><thead><tr><th>Category</th><th>Orders</th><th>Total ($)</th></tr></thead><tbody>#{trs}</tbody></table></body></html>"
        {:error, e} ->
          Logger.error("dashboard query failed: #{inspect(e)}")
          ""
      end

    conn
    |> put_resp_content_type("text/html; charset=utf-8")
    |> send_resp(200, body)
  end

  # ---------------------------------------------------------------------------
  # /health, /metrics
  # ---------------------------------------------------------------------------
  get "/health" do
    send_json(conn, 200, %{status: "ok"})
  end

  get "/metrics" do
    conn
    |> put_resp_content_type("text/plain; version=0.0.4")
    |> send_resp(200, Bench.Metrics.render())
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # ---------------------------------------------------------------------------
  # Metrics middleware and helpers
  # ---------------------------------------------------------------------------
  defp metrics_middleware(conn, _opts) do
    start = System.monotonic_time(:microsecond)
    conn = register_before_send(conn, fn conn ->
      elapsed = (System.monotonic_time(:microsecond) - start) / 1_000_000
      workload = workload_name(conn.request_path)
      method = conn.method |> to_string()
      status = conn.status |> Integer.to_string()
      Bench.Metrics.observe(workload, method, status || "0", elapsed)
      conn
    end)
    conn
  end

  defp workload_name(path) do
    cond do
      path == "/json" -> "json"
      String.starts_with?(path, "/products/") -> "product_read"
      path == "/orders" -> "order_write"
      path == "/dashboard" -> "dashboard"
      path in ["/health", "/metrics"] -> "infra"
      true -> "other"
    end
  end

  defp product_sql do
    "SELECT id, sku, name, description, category_id, price_cents, stock, active FROM products WHERE id = $1"
  end

  defp product_map([id, sku, name, description, category_id, price_cents, stock, active]) do
    %{id: id, sku: sku, name: name, description: description, category_id: category_id,
      price_cents: price_cents, stock: stock, active: active}
  end

  defp send_json(conn, status, map) do
    body = Jason.encode!(map)
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  defp html_escape(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace(~s("), "&quot;")
  end

  # Postgrex expects a uuid as a 16-byte binary. Convert a standard
  # "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" string to its raw bytes.
  defp uuid_binary(uuid) when is_binary(uuid) and byte_size(uuid) == 36 do
    hex = uuid |> String.replace("-", "")
    try do
      hex
      |> Base.decode16!(case: :mixed)
    rescue
      _ -> ""
    end
  end

  defp uuid_binary(_), do: ""
end
