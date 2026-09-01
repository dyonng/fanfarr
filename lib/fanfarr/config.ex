defmodule Fanfarr.Config do
  @moduledoc """
  Runtime configuration, resolved as: dashboard override, then environment
  variable, then default.

  The same pattern the rest of this stack uses -- env vars make the container
  runnable with nothing configured, while a value saved in Settings wins
  without a restart. `Fanfarr.Settings.Setting` rows exist only where an
  operator actually overrode something.
  """

  require Ash.Query

  @env_keys %{
    "plex_url" => "PLEX_URL",
    "plex_token" => "PLEX_TOKEN",
    "path_mappings" => "PATH_MAPPINGS",
    "ytdlp_proxy" => "YTDLP_PROXY"
  }

  @doc "The resolved value for a key, or nil."
  def get(key) when is_binary(key) do
    override(key) || env(key)
  end

  @doc "Plex connection for `Fanfarr.Plex.Client` calls; :error when unconfigured."
  def plex_config do
    url = get("plex_url")
    token = get("plex_token")

    if url in [nil, ""] or token in [nil, ""] do
      {:error, :plex_not_configured}
    else
      {:ok, %{base_url: String.trim_trailing(url, "/"), token: token}}
    end
  end

  @doc "Parsed path mappings, ready for `Fanfarr.PathMapping.to_local/2`."
  def path_mappings do
    Fanfarr.PathMapping.parse(get("path_mappings"))
  end

  defp override(key) do
    case Fanfarr.Settings.Setting
         |> Ash.Query.filter(key == ^key)
         |> Ash.read_one(authorize?: false) do
      {:ok, %{value: value}} when value not in [nil, ""] -> value
      _ -> nil
    end
  end

  defp env(key) do
    case Map.fetch(@env_keys, key) do
      {:ok, var} -> System.get_env(var)
      :error -> nil
    end
  end
end
