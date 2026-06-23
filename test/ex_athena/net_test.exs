defmodule ExAthena.NetTest do
  use ExUnit.Case, async: true

  alias ExAthena.Net

  describe "private_ip?/1 — IPv4" do
    test "loopback, private ranges, link-local and metadata are private" do
      assert Net.private_ip?({127, 0, 0, 1})
      assert Net.private_ip?({10, 1, 2, 3})
      assert Net.private_ip?({172, 16, 0, 1})
      assert Net.private_ip?({172, 31, 255, 255})
      assert Net.private_ip?({192, 168, 1, 1})
      assert Net.private_ip?({169, 254, 169, 254})
      assert Net.private_ip?({0, 0, 0, 0})
      assert Net.private_ip?({100, 64, 0, 1})
    end

    test "public addresses and the 172.16/12 boundaries are not private" do
      refute Net.private_ip?({8, 8, 8, 8})
      refute Net.private_ip?({1, 1, 1, 1})
      refute Net.private_ip?({172, 15, 0, 1})
      refute Net.private_ip?({172, 32, 0, 1})
      refute Net.private_ip?({100, 63, 0, 1})
    end
  end

  describe "private_ip?/1 — IPv6" do
    test "loopback, ULA, link-local and IPv4-mapped loopback are private" do
      assert Net.private_ip?({0, 0, 0, 0, 0, 0, 0, 1})
      assert Net.private_ip?({0xFC00, 0, 0, 0, 0, 0, 0, 1})
      assert Net.private_ip?({0xFE80, 0, 0, 0, 0, 0, 0, 1})
      # ::ffff:127.0.0.1
      assert Net.private_ip?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001})
    end

    test "global unicast is not private" do
      refute Net.private_ip?({0x2001, 0x4860, 0, 0, 0, 0, 0, 0x8888})
    end
  end

  describe "blocked_host?/1" do
    test "blocks private/loopback IP literals, allows public ones" do
      assert Net.blocked_host?("127.0.0.1")
      assert Net.blocked_host?("169.254.169.254")
      assert Net.blocked_host?("[::1]" |> String.trim_leading("[") |> String.trim_trailing("]"))
      refute Net.blocked_host?("8.8.8.8")
    end

    test "resolves a hostname and blocks it when it points at loopback" do
      # `localhost` resolves to 127.0.0.1 / ::1 (no external network needed).
      assert Net.blocked_host?("localhost")
    end
  end
end
