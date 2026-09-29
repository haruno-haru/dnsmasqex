# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.Upstream do
  @moduledoc false
  alias VintageNet.IP

  @spec normalize(String.t() | :inet.ip_address()) :: String.t() | :inet.ip_address()
  def normalize(value) when is_binary(value) do
    [destination | sources] = String.split(value, "@")
    {host, port} = split_port(destination)
    {address, scope} = scoped_address(host)
    source = source(sources, tuple_size(address))

    if port == "" and scope == "" and source == "",
      do: address,
      else: IP.ip_to_string(address) <> scope <> port <> source
  end

  def normalize(value), do: address!(value)

  defp scoped_address(host) do
    case String.split(host, "%") do
      [host] ->
        {address!(host), ""}

      [host, scope] ->
        address = address!(host)
        if tuple_size(address) != 8, do: raise(ArgumentError, "Scope requires an IPv6 upstream")
        {address, "%" <> interface!(scope)}

      _ ->
        raise ArgumentError, "Invalid upstream scope"
    end
  end

  defp split_port(value) do
    case String.split(value, "#") do
      [host] ->
        {host, ""}

      [host, port] ->
        case Integer.parse(port) do
          {number, ""} when number in 0..65_535 -> {host, "#" <> Integer.to_string(number)}
          _ -> raise ArgumentError, "Invalid upstream port"
        end

      _ ->
        raise ArgumentError, "Invalid upstream endpoint"
    end
  end

  defp source([], _family), do: ""
  defp source([value], family), do: "@" <> source_address(value, family, true)

  defp source([interface, value], family),
    do: "@" <> interface!(interface) <> "@" <> source_address(value, family, false)

  defp source(_values, _family), do: raise(ArgumentError, "Invalid upstream source")

  defp source_address(value, family, allow_interface?) do
    {host, port} = split_port(value)

    case IP.ip_to_tuple(host) do
      {:ok, address} when tuple_size(address) == family ->
        IP.ip_to_string(address) <> port

      {:ok, _address} ->
        raise ArgumentError, "Upstream and source must have the same address family"

      _ when allow_interface? ->
        interface!(host) <> port

      _ ->
        raise ArgumentError, "Invalid upstream source address"
    end
  end

  defp interface!(value) do
    if value =~ ~r/\A[a-zA-Z0-9_.:-]{1,15}\z/,
      do: value,
      else: raise(ArgumentError, "Invalid upstream interface")
  end

  defp address!(value) do
    with {:ok, address} <- IP.ip_to_tuple(value),
         true <- Enum.all?(Tuple.to_list(address), &is_integer/1) do
      address
    else
      _ -> raise ArgumentError, "Invalid IP address #{inspect(value)}"
    end
  end
end
