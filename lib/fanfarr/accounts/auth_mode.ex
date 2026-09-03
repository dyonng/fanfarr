defmodule Fanfarr.Accounts.AuthMode do
  @moduledoc """
  Whether a login is required.

  Derived from whether an operator account exists, which the boot-time seeder
  keeps in step with AUTH_USERNAME/AUTH_PASSWORD. Deriving it from the data
  rather than re-reading the environment means the answer cannot disagree with
  what would actually happen at the sign-in form.

  A second, independent switch -- Settings' "disable authentication for local
  addresses", the same convenience Sonarr and Radarr offer -- can additionally
  waive login for a single request without touching the account itself.
  `required?/1` takes that decision as an argument rather than making it,
  because whether a given request counts as local depends on the transport
  (`conn.remote_ip`) in a way this module has no access to on its own; compute
  it with `bypass_for_request?/1` at the call site, where the conn is at hand.
  """

  require Ash.Query

  @setting_key "bypass_auth_for_local_networks"

  @doc """
  Whether login is required for a request. Pass the result of
  `bypass_for_request?/1` (or omit it where there is no conn, e.g. outside a
  request) for the local-address bypass to take effect.
  """
  def required?(bypassed? \\ false) do
    account_exists?() and not bypassed?
  end

  @doc """
  Whether the local-address bypass applies to this request: the setting is on
  and the request's real TCP peer is local.
  """
  @spec bypass_for_request?(Plug.Conn.t()) :: boolean()
  def bypass_for_request?(conn) do
    bypass_enabled?() and Fanfarr.Accounts.LocalNetwork.local?(conn.remote_ip)
  end

  @doc "Whether the local-address bypass setting is turned on."
  def bypass_enabled? do
    case Fanfarr.Settings.Setting
         |> Ash.Query.filter(key == ^@setting_key)
         |> Ash.read_one(authorize?: false) do
      {:ok, %{value: "true"}} -> true
      _ -> false
    end
  end

  @doc "Turns the local-address bypass on or off."
  def set_bypass_enabled(enabled?) do
    Fanfarr.Settings.put_setting!(@setting_key, to_string(enabled?))
  end

  defp account_exists? do
    case Ash.read(Fanfarr.Accounts.User, authorize?: false) do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  end
end
