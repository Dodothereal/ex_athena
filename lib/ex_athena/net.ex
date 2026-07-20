defmodule ExAthena.Net do
  @moduledoc """
  Network address classification for the web tools' SSRF guard.

  `WebFetch` refuses URLs — the initial one and every redirect target — whose
  host is (or resolves to) a loopback, private, link-local, or otherwise
  non-public address, so the agent can't reach `localhost`, internal services,
  or the cloud metadata endpoint (`169.254.169.254`). The guard is on
  regardless of confinement; runs opt out with `allow_local_hosts: true`
  (see `ExAthena.Tools.WebFetch`).
  """

  import Bitwise, only: [&&&: 2]

  @doc """
  Whether `host` (a hostname or IP literal) should be blocked as non-public.

  IP literals are classified directly; hostnames are resolved (A + AAAA) and
  blocked if **any** resolved address is non-public (defeats DNS-rebinding to an
  internal IP). A host that fails to resolve is *not* blocked here — the HTTP
  request simply fails downstream.
  """
  @spec blocked_host?(String.t()) :: boolean()
  def blocked_host?(host) when is_binary(host) do
    host = String.trim_trailing(host, ".")

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, addr} -> private_ip?(addr)
      {:error, _} -> resolves_to_private?(host)
    end
  end

  defp resolves_to_private?(host) do
    charlist = String.to_charlist(host)

    addrs =
      for family <- [:inet, :inet6],
          {:ok, list} <- [:inet.getaddrs(charlist, family)],
          addr <- list,
          do: addr

    addrs != [] and Enum.any?(addrs, &private_ip?/1)
  end

  @doc "Whether an `:inet` address tuple is loopback / private / link-local / non-public."
  @spec private_ip?(:inet.ip_address()) :: boolean()
  # IPv4
  def private_ip?({0, _, _, _}), do: true
  def private_ip?({127, _, _, _}), do: true
  def private_ip?({10, _, _, _}), do: true
  def private_ip?({172, b, _, _}) when b in 16..31, do: true
  def private_ip?({192, 168, _, _}), do: true
  def private_ip?({169, 254, _, _}), do: true
  def private_ip?({100, b, _, _}) when b in 64..127, do: true
  def private_ip?({a, _, _, _}) when a >= 224, do: true
  def private_ip?({_, _, _, _}), do: false

  # IPv6
  def private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def private_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  # IPv4-mapped (::ffff:a.b.c.d) — classify the embedded v4
  def private_ip?({0, 0, 0, 0, 0, 0xFFFF, g, h}) do
    private_ip?({div(g, 256), rem(g, 256), div(h, 256), rem(h, 256)})
  end

  # fc00::/7 unique-local, fe80::/10 link-local
  def private_ip?({h1, _, _, _, _, _, _, _})
      when (h1 &&& 0xFE00) == 0xFC00 or (h1 &&& 0xFFC0) == 0xFE80,
      do: true

  def private_ip?({_, _, _, _, _, _, _, _}), do: false
end
