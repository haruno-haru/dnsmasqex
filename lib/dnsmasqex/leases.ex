# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.Leases do
  @moduledoc false

  alias Dnsmasqex.Event
  alias VintageNet.IP

  require Logger

  @doc """
  Publish the leases in a dnsmasq lease file
  """
  @spec update(VintageNet.ifname(), Path.t(), Event.t() | nil) :: :ok
  def update(ifname, lease_path, event \\ nil) do
    case File.read(lease_path) do
      {:ok, contents} ->
        format = if event && event.lease_length != nil, do: :duration, else: :expiry
        leases = contents |> parse(System.os_time(:second), format) |> observe_remaining(event)

        PropertyTable.put(VintageNet, property(ifname), leases)

      {:error, reason} ->
        Logger.error("#{ifname}: Failed to read dnsmasq leases from #{lease_path}: #{reason}")
        clear(ifname)
    end
  end

  defp observe_remaining(leases, %Event{lease_length: length, time_remaining: remaining, ip: ip})
       when is_integer(length) and is_integer(remaining) do
    Enum.map(leases, fn
      %{lease_nip: ^ip, leasetime: :unknown} = lease -> %{lease | leasetime: remaining}
      lease -> lease
    end)
  end

  defp observe_remaining(leases, _event), do: leases

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

  With `:duration` (the `no-RTC` build), the first column is the recorded lease
  length. It cannot establish remaining time: finite leases have
  `leasetime: :unknown` and `:lease_length`. A current script event may supply
  the remaining time for the lease it reports.
  """
  @spec parse(String.t(), integer(), :expiry | :duration) :: [map()]
  def parse(contents, now, format \\ :expiry) when format in [:expiry, :duration] do
    for line <- String.split(contents, "\n", trim: true),
        [expiry, identity, ip, hostname, client_id] <- [String.split(line)],
        {expiry, ""} <- [Integer.parse(expiry)],
        expiry >= 0,
        String.valid?(ip),
        {:ok, address} <- [IP.ip_to_tuple(ip)],
        identity <- [identity(address, identity, client_id)],
        identity != nil do
      Map.merge(identity, timing(expiry, now, format))
      |> Map.merge(%{
        lease_nip: ip,
        hostname: hostname(hostname)
      })
    end
  end

  defp identity(address, mac, client_id) when tuple_size(address) == 4,
    do: %{lease_mac: mac, lease_client_id: if(client_id == "*", do: nil, else: client_id)}

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

  defp timing(length, _now, :duration),
    do: %{leasetime: if(length == 0, do: :infinity, else: :unknown), lease_length: length}

  defp timing(expiry, now, :expiry), do: %{leasetime: leasetime(expiry, now)}

  defp property(ifname), do: ["interface", ifname, "dhcpd", "leases"]
end
