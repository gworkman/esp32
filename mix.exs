defmodule Esp32.MixProject do
  use Mix.Project

  def project do
    [
      app: :esp32,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      description: "Flash ESP32 microcontrollers with Elixir and Nerves",
      package: package(),
      deps: deps(),
      source_url: "https://github.com/gworkman/esp32"
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp package() do
    [
      # These are the default files included in the package
      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE CHANGELOG.md),
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/gworkman/esp32"}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:circuits_gpio, "~> 2.0"},
      {:circuits_uart, "~> 1.0"},
      {:jason, "~> 1.0"},
      {:ex_doc, "~> 0.14", only: :dev, runtime: false}
    ]
  end
end
