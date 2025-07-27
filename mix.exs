defmodule Ahoy.MixProject do
    use Mix.Project

    def project do
      [
        app: :ahoy,
        version: "0.1.0",
        elixir: "~> 1.14",
        start_permanent: Mix.env() == :prod,
        deps: deps(),
        escript: [main_module: Ahoy.CLI]
      ]
    end

    def application do
      [
        extra_applications: [:logger],
        mod: {Ahoy.Application, []}
      ]
    end

    defp deps do
      [
        # No external dependencies - pure Elixir/Erlang
      ]
    end
  end