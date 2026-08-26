defmodule Bench.Main do
  @moduledoc """
  Escript entry point. Starts the application (which starts the Postgrex
  pool, the metrics Agent, and the Bandit HTTP listener), then keeps the
  BEAM VM alive. The application stays up because Bandit's process is
  supervised and this `main/1` never returns.
  """
  def main(_argv) do
    # Configure logger from LOG_LEVEL before the app starts so the first
    # startup message is already at the right level. No per-request
    # logging is ever emitted at warn/error.
    Logger.configure(level: level_from_env())

    case Application.ensure_all_started(:bench) do
      {:ok, _} ->
        # The Bandit listener owns the VM; block this process forever so
        # the escript does not exit.
        Process.sleep(:infinity)

      {:error, reason} ->
        IO.puts(:stderr, "startup failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp level_from_env do
    case System.get_env("LOG_LEVEL", "warn") do
      "error" -> :error
      "info" -> :info
      "debug" -> :debug
      _ -> :warn
    end
  end
end
