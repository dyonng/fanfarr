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

  # The raw value is baked in and trimmed at runtime, because a module
  # attribute cannot call a function defined in its own module.
  @raw_build_ref System.get_env("BUILD_REF")

  # Mix has no way to know this module read an environment variable, so an
  # unchanged source file is left alone and the module keeps whatever ref it
  # was first compiled with. A version that silently reports the wrong build is
  # worse than no version at all, so recompilation is requested explicitly.
  @doc false
  def __mix_recompile__?, do: System.get_env("BUILD_REF") != @raw_build_ref

  @doc "The application version, e.g. `0.1.0`."
  @spec version() :: String.t()
  def version, do: @version

  @doc "Short commit this image was built from, or nil for a local build."
  @spec build_ref() :: String.t() | nil
  def build_ref do
    case @raw_build_ref do
      nil ->
        nil

      raw ->
        case String.trim(raw) do
          "" -> nil
          trimmed -> String.slice(trimmed, 0, 7)
        end
    end
  end

  @doc """
  Cache-busting token for static assets that are linked by a stable URL.

  The icons are deliberately linked undigested (see root.html.heex), so this
  is what makes a browser notice that the artwork changed.
  """
  @spec asset_version() :: String.t()
  def asset_version, do: build_ref() || @version

  @doc """
  Human-readable version for the UI and the health endpoint.

      "0.1.0 (a1b2c3d)"   # built by CI
      "0.1.0 (dev)"       # built locally
  """
  @spec display() :: String.t()
  def display, do: "#{@version} (#{build_ref() || "dev"})"
end
