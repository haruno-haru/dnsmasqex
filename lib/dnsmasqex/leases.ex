# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.Leases do
  @moduledoc false

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
  infinite leases and `*` for a missing hostname.
  """
  @spec parse(String.t(), integer()) :: [map()]
  def parse(contents, now) do
    for line <- String.split(contents, "\n", trim: true),
        [expiry, mac, ip, hostname | _] <- [String.split(line)],
        {expiry, ""} <- [Integer.parse(expiry)] do
      %{
        leasetime: leasetime(expiry, now),
        lease_nip: ip,
        lease_mac: mac,
        hostname: if(hostname == "*", do: "", else: hostname)
      }
    end
  end

  defp leasetime(0, _now), do: :infinity
  defp leasetime(expiry, now), do: max(expiry - now, 0)

  defp property(ifname), do: ["interface", ifname, "dhcpd", "leases"]
end
