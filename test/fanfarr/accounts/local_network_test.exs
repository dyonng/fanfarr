defmodule Fanfarr.Accounts.LocalNetworkTest do
  use ExUnit.Case, async: true

  alias Fanfarr.Accounts.LocalNetwork

  describe "IPv4" do
    test "loopback is local" do
      assert LocalNetwork.local?({127, 0, 0, 1})
      assert LocalNetwork.local?({127, 1, 2, 3})
    end

    test "the private ranges are local" do
      assert LocalNetwork.local?({10, 0, 0, 5})
      assert LocalNetwork.local?({172, 16, 0, 1})
      assert LocalNetwork.local?({172, 31, 255, 255})
      assert LocalNetwork.local?({192, 168, 1, 121})
    end

    test "172.x outside 16-31 is not local" do
      refute LocalNetwork.local?({172, 15, 0, 1})
      refute LocalNetwork.local?({172, 32, 0, 1})
    end

    test "link-local is local" do
      assert LocalNetwork.local?({169, 254, 1, 1})
    end

    test "a public address is not local" do
      refute LocalNetwork.local?({8, 8, 8, 8})
      refute LocalNetwork.local?({1, 1, 1, 1})
    end
  end

  describe "IPv6" do
    test "::1 is local" do
      assert LocalNetwork.local?({0, 0, 0, 0, 0, 0, 0, 1})
    end

    test "unique local (fc00::/7) is local" do
      assert LocalNetwork.local?({0xFC00, 0, 0, 0, 0, 0, 0, 1})
      assert LocalNetwork.local?({0xFD12, 0, 0, 0, 0, 0, 0, 1})
    end

    test "link-local (fe80::/10) is local" do
      assert LocalNetwork.local?({0xFE80, 0, 0, 0, 0, 0, 0, 1})
    end

    test "a public IPv6 address is not local" do
      refute LocalNetwork.local?({0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888})
    end

    test "an IPv4-mapped address defers to the IPv4 check" do
      # ::ffff:192.168.1.1
      assert LocalNetwork.local?({0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x0101})
      # ::ffff:8.8.8.8
      refute LocalNetwork.local?({0, 0, 0, 0, 0, 0xFFFF, 0x0808, 0x0808})
    end
  end
end
