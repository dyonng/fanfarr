defmodule RuntimeDepsTest do
  @moduledoc """
  Modules the application calls must come from dependencies that exist in a
  production release.

  `req` was reachable in dev and test through igniter, a dev/test-only dep,
  and absent from the release. Every test passed; every Plex call in
  production raised. The check here is the one that would have caught it.
  """
  use ExUnit.Case, async: true

  # Top-level modules used from lib/, mapped to the dep that provides them.
  @external_modules %{
    "Req" => :req,
    "Jason" => :jason,
    "Oban" => :oban,
    "Ash" => :ash,
    "TwMerge" => :tw_merge,
    "Phoenix" => :phoenix,
    "Plug" => :plug
  }

  test "every external module used from lib/ comes from a runtime dependency" do
    deps = Mix.Project.config()[:deps]

    runtime =
      deps
      |> Enum.filter(fn
        {_name, opts} when is_list(opts) -> runtime?(opts)
        {_name, _req, opts} when is_list(opts) -> runtime?(opts)
        _ -> true
      end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    used =
      Path.wildcard("lib/**/*.ex")
      |> Enum.flat_map(fn file ->
        source = File.read!(file)

        for {mod, dep} <- @external_modules,
            Regex.match?(~r/(?<![\w.])#{mod}\./, source),
            do: {mod, dep, file}
      end)

    for {mod, dep, file} <- used, dep != :plug do
      assert MapSet.member?(runtime, dep),
             "#{file} uses #{mod} but :#{dep} is not a runtime dependency in mix.exs " <>
               "(missing, or scoped with only:). It will not exist in the release."
    end
  end

  test "the Dockerfile compiles strictly, and before assets.deploy" do
    dockerfile = File.read!("Dockerfile")
    strict = :binary.match(dockerfile, "RUN mix compile --warnings-as-errors")
    assets = :binary.match(dockerfile, "RUN mix assets.deploy")

    assert strict != :nomatch,
           "the image build must fail on warnings; a warning is a missing module"

    assert assets != :nomatch

    {strict_at, _} = strict
    {assets_at, _} = assets

    assert strict_at < assets_at,
           "assets.deploy compiles too; a strict compile after it is a no-op and guards nothing"
  end

  test "a v-tag release would carry a matching mix.exs version" do
    # docker.yml tags an image from the git tag while the running app reports
    # mix.exs. If the bump workflow ever stops editing mix.exs, an image
    # labelled v1.2.3 would report something else, and the version line on the
    # System page is what bug reports quote.
    workflow = File.read!(".github/workflows/version.yml")

    rewrites_mix =
      workflow
      |> String.split("\n")
      |> Enum.any?(&(&1 =~ "sed -i" and &1 =~ "mix.exs" and &1 =~ "version:"))

    assert rewrites_mix, "the bump workflow must rewrite the version in mix.exs"
    assert workflow =~ "git tag -a", "it must tag the commit carrying the new version"
    assert workflow =~ "workflow_dispatch", "bumping is a decision, not a push side effect"
  end

  defp runtime?(opts) do
    case Keyword.get(opts, :only) do
      nil -> true
      only -> :prod in List.wrap(only)
    end
  end
end
