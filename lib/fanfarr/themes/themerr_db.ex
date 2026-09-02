defmodule Fanfarr.Themes.ThemerrDB do
  @moduledoc "The one place the ThemerrDB base URL and reachability live."

  @base_url "https://app.lizardbyte.dev/ThemerrDB"

  def base_url, do: @base_url

  @doc "A quick probe of the database host. A known-present entry, so a 200 means real data flows."
  @spec reachable?() :: :ok | {:error, term()}
  def reachable? do
    opts =
      [retry: false, receive_timeout: 5_000, connect_options: [timeout: 5_000]]
      |> Keyword.merge(Application.get_env(:fanfarr, :req_options, []))

    case Req.get("#{@base_url}/tv_shows/imdb/tt0388629.json", opts) do
      {:ok, %{status: status}} when status in [200, 404] -> :ok
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
