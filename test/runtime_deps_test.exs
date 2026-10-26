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

  test "the image removes the roots affected by the eMudhra compromise" do
    dockerfile = File.read!("Dockerfile")

    # Why this needs a test rather than a comment: the removal is a sed against
    # filenames Debian owns. If a future ca-certificates package renames them,
    # the sed matches nothing, the build succeeds, and the image ships trusting
    # a root whose intermediates were compromised. Erlang's TLS client does not
    # consult revocation or CT data, so losing the root is the only protection
    # there is -- and Debian bookworm has no fixed package to inherit it from.
    for root <- ["emSign_ECC_Root_CA_-_C3", "emSign_Root_CA_-_C1"] do
      assert dockerfile =~ "s|^mozilla/#{root}.crt|!&|",
             "#{root} is compromised and still trusted by the image build"
    end

    assert dockerfile =~ "update-ca-certificates",
           "disabling a root in ca-certificates.conf does nothing until the bundle is rebuilt"

    refute dockerfile =~ "emSign_Root_CA_-_G1",
           "eMudhra states G1 is not being removed; dropping it breaks sites that use it"

    assert dockerfile =~ "! grep -qE '^mozilla/emSign_",
           "the build should fail, not pass quietly, when these patterns stop matching"
  end

  defp runtime?(opts) do
    case Keyword.get(opts, :only) do
      nil -> true
      only -> :prod in List.wrap(only)
    end
  end
end
