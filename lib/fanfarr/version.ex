defmodule Fanfarr.Version do
  @moduledoc """
  What build this is.

  Self-hosters report bugs by version, so the number has to be visible in the
  UI and precise enough to identify a specific image. `0.1.0` alone is not:
  every `latest` pull between releases carries it. The commit is what actually
  distinguishes them.

  Both values are captured **at compile time**, so a running container cannot
  be made to misreport itself by setting an environment variable, and the
  release needs no build-related env at runtime. `BUILD_REF` is passed as a
  Docker build arg by the release workflow; a local `mix release` simply has
  no ref, and says so.
  """

  @version Mix.Project.config()[:version]

  @build_ref (case System.get_env("BUILD_REF") do
                nil -> nil
                "" -> nil
                ref -> ref |> String.trim() |> String.slice(0, 7)
              end)

  @doc "The application version, e.g. `0.1.0`."
  @spec version() :: String.t()
  def version, do: @version

  @doc "Short commit this image was built from, or nil for a local build."
  @spec build_ref() :: String.t() | nil
  def build_ref, do: @build_ref

  @doc """
  Human-readable version for the UI and the health endpoint.

      "0.1.0 (a1b2c3d)"   # built by CI
      "0.1.0 (dev)"       # built locally
  """
  @spec display() :: String.t()
  def display, do: "#{@version} (#{@build_ref || "dev"})"
end
