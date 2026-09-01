defmodule ProdConfigTest do
  @moduledoc """
  Guards production configuration that cannot be exercised from the test env.

  `force_ssl` is compile-time and prod-only, so no request test can catch it
  being enabled. It has to be asserted against the config file itself.
  """
  use ExUnit.Case, async: true

  test "production does not force SSL" do
    config = File.read!("config/prod.exs")

    enabled? =
      config
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
      |> Enum.any?(&String.contains?(&1, "force_ssl"))

    refute enabled?, """
    config/prod.exs enables force_ssl.

    Fanfarr is a LAN appliance reached by IP. force_ssl answers 301 to https://
    for every host except localhost and 127.0.0.1, which makes the dashboard
    unreachable at http://<lan-ip>:7373 while the container healthcheck keeps
    passing -- it curls localhost, the excluded host.

    Where TLS is wanted, a reverse proxy terminates it and issues its own
    redirect; Plug.RewriteOn in the endpoint honours X-Forwarded-Proto so
    generated URLs remain correct.
    """
  end

  test "the container healthcheck does not rely on an SSL-excluded host" do
    dockerfile = File.read!("Dockerfile")

    [healthcheck] =
      dockerfile
      |> String.split("\n")
      |> Enum.filter(&String.contains?(&1, "/health"))

    refute String.contains?(healthcheck, "http://localhost"),
           """
           The healthcheck requests http://localhost, which Phoenix's force_ssl
           config treats as a special case. A check on that host can pass while
           every other request is redirected. Use 127.0.0.1 with an explicit
           Host header instead, so the check follows the same path a browser does.
           """
  end
end
