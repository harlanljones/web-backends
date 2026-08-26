defmodule Bench.Metrics do
  @moduledoc """
  Minimal in-process Prometheus histogram.

  Exposes `http_request_duration_seconds_bucket{...}` plus `_count` and
  `_sum`, with `path` normalized to the workload name (`json`,
  `product_read`, `order_write`, `dashboard`, `infra`).

  State lives in a named ETS table. For each (path, method, status) we
  keep an unordered list of every observed value, then bucket them at
  render time. At benchmark rates the per-request list is a small cost
  per label set; keeping it simple and exact beats pre-bucketing under
  contention.
  """

  use Agent

  @buckets [0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1.0, 2.0, 5.0]
  @metric "http_request_duration_seconds"

  def start_link(_opts) do
    Agent.start_link(fn -> :ets.new(:bench_metrics, [:set, :public, :named_table]) end, name: __MODULE__)
  end

  def observe(path, method, status, seconds) do
    value = seconds * 1.0
    Agent.update(__MODULE__, fn _ ->
      key = {path, method, status, make_ref()}
      :ets.insert(:bench_metrics, {key, value})
    end)
  end

  def render do
    rows = Agent.get(__MODULE__, fn _ -> collect_rows() end)

    lines =
      if rows == [] do
        ["# benchmark metrics: no requests recorded"]
      else
        Enum.map(rows, &render_row/1)
      end

    Enum.join(lines, "") <> "\n"
  end

  # Collect per (path, method, status) the list of observed values.
  defp collect_rows do
    :ets.tab2list(:bench_metrics)
    |> Enum.group_by(fn {{p, m, s, _ref}, _v} -> {p, m, s} end)
    |> Map.to_list()
    |> Enum.map(fn {{p, m, s}, pairs} ->
      {p, m, s, Enum.map(pairs, fn {_k, v} -> v end)}
    end)
    |> Enum.sort_by(fn {p, m, s, _} -> {p, m, s} end)
  end

  defp render_row({path, method, status, values}) do
    count = length(values)
    sum = Enum.sum(values)

    bucket_lines =
      @buckets
      |> Enum.map(fn le ->
        acc = Enum.count(values, &(&1 <= le))
        ~s(#{"#{@metric}"}_bucket{le="#{float(le)}",path="#{path}",method="#{method}",status="#{status}"} #{acc}\n)
      end)
      |> Enum.join()

    count_line = ~s(#{"#{@metric}"}_count{path="#{path}",method="#{method}",status="#{status}"} #{count}\n)
    sum_line = ~s(#{"#{@metric}"}_sum{path="#{path}",method="#{method}",status="#{status}"} #{float(sum)}\n)

    bucket_lines <> count_line <> sum_line
  end

  defp float(f) when is_integer(f), do: Integer.to_string(f)
  defp float(f), do: :erlang.float_to_binary(f * 1.0, decimals: 6)
end
