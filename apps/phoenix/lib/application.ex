defmodule Bench.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    port = String.to_integer(System.get_env("PORT") || "8080")

    children = [
      # Postgrex pool sized to DB_POOL_SIZE (default 32). This is the
      # single database pool; the framework must not open a second one.
      # The connection options come from DATABASE_URL (libpq form).
      {Postgrex, pg_opts()},
      # A tiny in-process Prometheus histogram store (Agent-backed).
      Bench.Metrics,
      # Bandit (a Plug server) is the HTTP listener.
      {Bandit,
       plug: Bench.Router,
       scheme: :http,
       port: port,
       startup_log: false}
    ]

    opts = [strategy: :one_for_one, name: Bench.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp pool_size do
    String.to_integer(System.get_env("DB_POOL_SIZE") || "32")
  end

  defp pg_opts do
    [
      name: :bench_pg,
      pool_size: pool_size(),
      log: :error
    ] |> Keyword.merge(parse_database_url(System.get_env("DATABASE_URL") || ""))
  end

  # Parse a libpq URL (postgres://user:pass@host:port/db) into the
  # Postgrex options (hostname/port/database/username/password).
  defp parse_database_url(url) do
    case URI.parse(url) do
      %URI{scheme: "postgres"} = uri ->
        db = uri.path |> String.trim_leading("/")
        [hostname: uri.host || "localhost",
         port: uri.port || 5432,
         database: db,
         username: uri.userinfo && (uri.userinfo |> String.split(":", parts: 2) |> List.first()),
         password: uri.userinfo && (uri.userinfo |> String.split(":", parts: 2) |> Enum.at(1))]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      _ ->
        []
    end
  end
end
