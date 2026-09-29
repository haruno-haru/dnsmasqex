# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.Statistics do
  @moduledoc """
  Read the running daemon's native CHAOS TXT statistics.

  Counters are snapshots, reset when dnsmasq restarts. They are unavailable
  with `port=0` or `no-ident`. `:servers` preserves dnsmasq's per-server text,
  since its fields depend on the installed version. No external resolver is
  used: each request goes to the supplied endpoint.
  """

  @counters [:cachesize, :insertions, :evictions, :misses, :hits]

  @spec query({:inet.ip_address(), 1..65_535}, pos_integer()) :: {:ok, map()} | {:error, term()}
  def query({address, port}, timeout \\ 1_000) when port in 1..65_535 and timeout > 0 do
    Enum.reduce_while(@counters ++ [:servers], {:ok, %{}}, fn name, {:ok, stats} ->
      values =
        :inet_res.lookup(
          String.to_charlist("#{name}.bind"),
          :chaos,
          :txt,
          [nameservers: [{address, port}], timeout: timeout, retry: 1],
          timeout
        )

      strings = Enum.map(values, &IO.iodata_to_binary/1)

      case parse(name, strings) do
        {:ok, value} -> {:cont, {:ok, Map.put(stats, name, value)}}
        error -> {:halt, error}
      end
    end)
  end

  defp parse(:servers, servers), do: {:ok, servers}

  defp parse(name, [value]) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> {:ok, number}
      _ -> {:error, {:invalid_statistic, name, value}}
    end
  end

  defp parse(name, _values), do: {:error, {:statistics_unavailable, name}}
end
