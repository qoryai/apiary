defmodule Apiary.MixProject do
  use Mix.Project

  def project do
    [
      app: :apiary,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      name: "Qory",
      docs: docs()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Apiary.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:bcrypt_elixir, "~> 3.0"},
      {:phoenix, "~> 1.8.14"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:stream_data, "~> 1.0", only: [:dev, :test]},
      {:jsv, "~> 0.23"},
      {:phoenix_live_dashboard, "~> 0.9.1"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.3.0"},
      {:bandit, "~> 1.5"},
      {:cloak_ecto, "~> 1.3"},
      {:logger_json, "~> 7.0"},
      {:gen_smtp, "~> 1.3"},
      # In every environment, the release build included: the image builds the docs it
      # serves at /docs. Never started, so it is not in the release.
      {:ex_doc, "~> 0.38", runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind apiary", "esbuild apiary"],
      "assets.deploy": [
        "compile",
        "tailwind apiary --minify",
        "esbuild apiary --minify",
        "phx.digest"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "docs --warnings-as-errors",
        "test"
      ]
    ]
  end

  # The documentation ships with the application: the guides and the module reference are
  # built into priv/static/docs, which every instance serves at /docs.
  defp docs do
    [
      main: "quickstart",
      output: "priv/static/docs",
      formatters: ["html"],
      logo: "priv/static/images/logo.svg",
      favicon: "priv/static/favicon.svg",
      api_reference: true,
      extras: [
        "guides/quickstart.md",
        "guides/install.md",
        "guides/upgrading.md",
        "guides/backup.md",
        "guides/retention.md",
        "guides/hosting-checklist.md",
        "guides/security-policy.md",
        "guides/runner-file.md",
        "guides/contract.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        "Start here": ["guides/quickstart.md"],
        "Self-hosting": [
          "guides/install.md",
          "guides/upgrading.md",
          "guides/backup.md",
          "guides/retention.md",
          "guides/hosting-checklist.md"
        ],
        "Using Qory": ["guides/security-policy.md", "guides/runner-file.md"],
        Reference: ["guides/contract.md", "CHANGELOG.md"]
      ],
      groups_for_modules: [
        "Accounts and organisations": [~r/^Apiary\.Accounts/, ~r/^Apiary\.Organisations/],
        "Access keys": [~r/^Apiary\.AccessKeys/, ~r/^Apiary\.Encrypted/, Apiary.Vault],
        "Runs and the record": [~r/^Apiary\.Runs/],
        "Security policy": [~r/^Apiary\.Policy/],
        Retention: [~r/^Apiary\.Retention/],
        "Server contract": [~r/^Apiary\.Contract/, ~r/^ApiaryWeb\.Contract/],
        Operation: [Apiary.Release, ~r/^Apiary\.Release\./, Apiary.Mailer, Apiary.Repo],
        Console: [~r/^ApiaryWeb/],
        "Mix tasks": [~r/^Mix\.Tasks/]
      ]
    ]
  end
end
