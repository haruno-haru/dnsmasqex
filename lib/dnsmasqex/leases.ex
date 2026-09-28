# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.Leases do
  @moduledoc false

  alias VintageNet.IP

  require Logger

  @doc """
  Publish the leases in a dnsmasq lease file
  """
  @spec update(VintageNet.ifname(), Path.t()) :: :ok
  def update(ifname, lease_path) do
    case File.read(lease_path) do
      {:ok, contents} ->
        PropertyTable.put(VintageNet, property(ifname), parse(contents, System.os_time(:second)))

      {:error, reason} ->
        Logger.error("#{ifname}: Failed to read dnsmasq leases from #{lease_path}: #{reason}")
        clear(ifname)
    end
  end

  @doc """
  Remove the published leases
  """
  @spec clear(VintageNet.ifname()) :: :ok
  def clear(ifname), do: PropertyTable.delete(VintageNet, property(ifname))

  @doc """
  Parse a dnsmasq lease file

  Each line is `expiry mac ip hostname client_id`, with an expiry of 0 for
  infinite leases and `*` for a missing hostname. DHCPv6 uses an IAID instead
  of a MAC and a DUID as the client identifier. Its leases have `lease_mac: nil`,
  `:lease_iaid` and `:lease_duid`. A temporary address has an IAID prefixed by `T`.
  """
  @spec parse(String.t(), integer()) :: [map()]
  def parse(contents, now) do
    for line <- String.split(contents, "\n", trim: true),
        [expiry, identity, ip, hostname, client_id] <- [String.split(line)],
        {expiry, ""} <- [Integer.parse(expiry)],
        expiry >= 0,
        {:ok, address} <- [IP.ip_to_tuple(ip)],
        identity <- [identity(address, identity, client_id)],
        identity != nil do
      Map.merge(identity, %{
        leasetime: leasetime(expiry, now),
        lease_nip: ip,
        hostname: hostname(hostname)
      })
    end
  end

  defp identity(address, mac, _client_id) when tuple_size(address) == 4,
    do: %{lease_mac: mac}

  defp identity(_address, iaid, duid) do
    with true <- iaid =~ ~r/\AT?[0-9]+\z/,
         {number, ""} when number in 0..0xFFFFFFFF <-
           iaid |> String.replace_prefix("T", "") |> Integer.parse() do
      %{lease_mac: nil, lease_iaid: iaid, lease_duid: if(duid == "*", do: nil, else: duid)}
    else
      _ -> nil
    end
  end

  defp hostname("*"), do: ""
  defp hostname(hostname), do: hostname

  defp leasetime(0, _now), do: :infinity
  defp leasetime(expiry, now), do: max(expiry - now, 0)

  defp property(ifname), do: ["interface", ifname, "dhcpd", "leases"]
end
