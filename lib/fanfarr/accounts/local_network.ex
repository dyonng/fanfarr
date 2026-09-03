defmodule Fanfarr.Accounts.LocalNetwork do
  @moduledoc """
  Whether an address is "local" in the sense Sonarr and Radarr mean it for
  their own "disable authentication for local addresses" setting: loopback
  and the private ranges an actual LAN client would have.

  Checked against the raw TCP peer address (`conn.remote_ip`), never a
  client-supplied header -- a request cannot claim to be local by adding an
  `X-Forwarded-For`, which would defeat the point of gating on this at all.
  If Fanfarr sits behind a reverse proxy, this is the proxy's own address,
  not the original client's; that is the same trade-off Sonarr and Radarr
  make by default.
  """

  @spec local?(:inet.ip_address()) :: boolean()
  def local?({127, _, _, _}), do: true
  def local?({10, _, _, _}), do: true
  def local?({172, b, _, _}) when b in 16..31, do: true
  def local?({192, 168, _, _}), do: true
  def local?({169, 254, _, _}), do: true
  def local?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  # IPv4-mapped IPv6 (::ffff:a.b.c.d), as an IPv4 socket seen through a
  # dual-stack listener shows up -- unwrap and re-check as IPv4.
  def local?({0, 0, 0, 0, 0, 0xFFFF, high, low}) do
    <<a, b>> = <<high::16>>
    <<c, d>> = <<low::16>>
    local?({a, b, c, d})
  end

  # Unique local (fc00::/7) and link-local (fe80::/10).
  def local?({first, _, _, _, _, _, _, _}) when first in 0xFC00..0xFDFF, do: true
  def local?({first, _, _, _, _, _, _, _}) when first in 0xFE80..0xFEBF, do: true

  def local?(_), do: false
end
