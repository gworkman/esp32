defmodule Esp32.MixProject do
  use Mix.Project

  def project do
    [
      app: :esp32,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: [
        tidewave:
          "run --no-halt -e 'Agent.start(fn -> Bandit.start_link(plug: Tidewave, port: 4000) end)'"
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:tidewave, "~> 0.5", only: [:dev]},
      {:bandit, "~> 1.0", only: [:dev]},
      {:circuits_gpio, "~> 2.0"},
      {:circuits_uart, "~> 1.0"}
    ]
  end
end
