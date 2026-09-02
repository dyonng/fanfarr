defmodule Fanfarr.MixProject do
  use Mix.Project

  def project do
    [
      app: :fanfarr,
      version: "0.1.21",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() != :dev
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Fanfarr.Application, []},
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
      # Every Plex, ThemerrDB and poster request. This was missing: Req reached
      # dev and test transitively through igniter (dev/test only), compiled
      # fine there, and was simply absent from the production release -- where
      # every call to it raised UndefinedFunctionError. Guarded by
      # test/runtime_deps_test.exs and the strict compile in the Dockerfile.
      {:req, "~> 0.5"},
      {:simple_sat, "~> 0.1"},
      {:ash_authentication, "~> 4.0"},
      {:ash_authentication_phoenix, "~> 2.0"},
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:open_api_spex, "~> 3.0"},
      {:oban, "~> 2.0"},
      {:ash_json_api, "~> 1.0"},
      {:ash_oban, "~> 0.8"},
      {:ash_phoenix, "~> 2.0"},
      {:ash_sqlite, "~> 0.2"},
      {:ash, "~> 3.0"},
      # Runtime dep of the vendored SaladUI components (lib/fanfarr_web/components/vendor).
      {:tw_merge, "~> 0.1"},
      {:mox, "~> 1.2", only: :test},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:phoenix, "~> 1.8.13"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      # Lucide, not Heroicons: the UI is built on shadcn components and Lucide
      # is the set they are drawn against. Sparse-checked out and never
      # compiled -- the Tailwind plugin in assets/vendor/lucide.js reads the
      # SVGs directly and emits only the icons actually referenced.
      {:lucide,
       github: "lucide-icons/lucide", sparse: "icons", app: false, compile: false, depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
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
      test: ["ash.setup --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind fanfarr", "esbuild fanfarr"],
      "assets.deploy": [
        # `compile` must come first: LiveView writes colocated CSS/JS into
        # _build/$MIX_ENV/phoenix-colocated during compilation, and app.css
        # imports it. Without this, a clean prod build (the Docker image, or
        # CI) fails to resolve colocated.css. `assets.build` already does this;
        # the generated `assets.deploy` did not.
        "compile",
        "tailwind fanfarr --minify",
        "esbuild fanfarr --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
      "ash.setup": ["ash.setup", "run priv/repo/seeds.exs"]
    ]
  end
end
