defmodule Fanfarr.Accounts.Seed do
  @moduledoc """
  Applies the operator credentials from the environment at boot.

  There is no sign-up. Fanfarr is a single-user appliance, so the account is
  declared the way everything else about the container is -- in the compose
  file -- and reconciled on every start:

      AUTH_USERNAME=admin
      AUTH_PASSWORD=something-long

  Setting them creates the user, or updates the existing one to match. That
  means changing the password is an edit to compose and a restart, and a
  forgotten password is recovered the same way, with no reset flow, no mailer
  and no console access needed.

  **With neither set, authentication is off and the dashboard is open**, which
  is how Sonarr and Radarr also start. That is a reasonable default on a
  trusted LAN and a bad one anywhere else, so it is logged loudly on every
  boot rather than left to be discovered.
  """
  require Logger

  @doc "Reconciles the operator account with the environment. Called at boot."
  def run do
    case {trimmed("AUTH_USERNAME"), System.get_env("AUTH_PASSWORD")} do
      {nil, _} -> warn_open()
      {_, nil} -> warn_open()
      {_, ""} -> warn_open()
      {username, password} -> upsert(username, password)
    end
  end

  defp upsert(username, password) do
    case existing(username) do
      nil ->
        Fanfarr.Accounts.User
        |> Ash.Changeset.for_create(:register_with_password, %{
          username: username,
          password: password,
          password_confirmation: password
        })
        |> Ash.create!(authorize?: false)

        Logger.info("[fanfarr] created operator account #{username}")

      user ->
        # Reconcile rather than skip: an operator who edits AUTH_PASSWORD in
        # compose expects the new value to work after a restart, and that is
        # the whole recovery story.
        user
        |> Ash.Changeset.for_update(:set_password, %{password: password})
        |> Ash.update!(authorize?: false)

        Logger.info("[fanfarr] operator account #{username} is up to date")
    end

    # Any account other than the declared one is stale -- a renamed
    # AUTH_USERNAME would otherwise leave the old login working forever.
    Fanfarr.Accounts.User
    |> Ash.read!(authorize?: false)
    |> Enum.reject(&(to_string(&1.username) == username))
    |> Enum.each(fn stale ->
      Ash.destroy!(stale, authorize?: false)
      Logger.info("[fanfarr] removed stale account #{stale.username}")
    end)
  rescue
    error ->
      # Boot must not die over a credential problem -- an unreachable
      # dashboard is worse than an open one, and the operator needs the app up
      # to fix it. But the message and stacktrace go out in full: an earlier
      # version logged only Exception.message/1, which for an Ash error is
      # empty, and a real misconfiguration looked like a blank line.
      Logger.error("""
      [fanfarr] could not apply AUTH_USERNAME/AUTH_PASSWORD.
      Authentication may not be configured as you expect.

      #{Exception.format(:error, error, __STACKTRACE__)}
      """)

      :error
  end

  defp existing(username) do
    Fanfarr.Accounts.User
    |> Ash.read!(authorize?: false)
    |> Enum.find(&(String.downcase(to_string(&1.username)) == String.downcase(username)))
  end

  defp warn_open do
    # Remove any account left from a previous configuration, so deleting the
    # env vars actually turns authentication off rather than stranding a
    # login nobody has the password for.
    case Ash.read(Fanfarr.Accounts.User, authorize?: false) do
      {:ok, [_ | _] = users} ->
        Enum.each(users, &Ash.destroy!(&1, authorize?: false))

        Logger.warning(
          "[fanfarr] AUTH_USERNAME/AUTH_PASSWORD unset; removed the previous account"
        )

      _ ->
        :ok
    end

    Logger.warning(
      "[fanfarr] ================================================================\n" <>
        "[fanfarr] AUTHENTICATION IS DISABLED. The dashboard is open to anyone\n" <>
        "[fanfarr] who can reach this port. Set AUTH_USERNAME and AUTH_PASSWORD\n" <>
        "[fanfarr] in your compose file to require a login.\n" <>
        "[fanfarr] ================================================================"
    )

    :open
  end

  defp trimmed(var) do
    case System.get_env(var) do
      nil ->
        nil

      value ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end
    end
  end
end
