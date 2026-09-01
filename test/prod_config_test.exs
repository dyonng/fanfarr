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

  test "production does not pin the websocket origin to a single host" do
    runtime = File.read!("config/runtime.exs")

    assert String.contains?(runtime, "check_origin:"), """
    config/runtime.exs does not set check_origin.

    Phoenix then validates the browser Origin against `url: [host:]`, which for
    this appliance defaults to "localhost". Reaching the server by LAN IP,
    hostname or Tailscale name is refused, and the failure is quiet and
    confusing: the page renders statically, the LiveView socket never
    connects, and the browser retries forever.
    """

    # And it must not be hardcoded true -- that reintroduces the same failure.
    refute Regex.match?(~r/check_origin:\s*true/, runtime),
           "check_origin is hardcoded true, which pins the socket to one host again"
  end

  test "the auth pages do not carry Ash Framework branding" do
    overrides = File.read!("lib/fanfarr_web/auth_overrides.ex")

    assert String.contains?(overrides, "Components.Banner"), """
    The banner is not overridden, so the sign-in page shows the Ash Framework
    logo -- fetched from ash-hq.org, which an appliance on a private network
    may not even be able to reach.
    """

    assert String.contains?(overrides, "set :image_url, nil"),
           "the off-site default logo must be cleared, not merely restyled"
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
