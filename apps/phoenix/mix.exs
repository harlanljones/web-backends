defmodule Bench.MixProject do
  use Mix.Project

  def project do
    [
      app: :bench,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: Bench.Main],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Bench.Application, []}
    ]
  end

  # Lean deps: Bandit HTTP server, Plug router, Postgrex DB pool, Jason JSON.
  # No Phoenix / no Ecto -- the benchmark measures the framework, not an ORM.
  defp deps do
    [
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.16"},
      {:postgrex, "~> 0.19"},
      {:jason, "~> 1.4"}
    ]
  end
end
