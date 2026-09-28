# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.Config.Names do
  @moduledoc false

  @spec dns!(String.t()) :: String.t()
  def dns!(name) do
    if dns?(name), do: name, else: raise(ArgumentError, "Invalid DNS name #{inspect(name)}")
  end

  @spec dns?(term()) :: boolean()
  def dns?(name) when is_binary(name) and byte_size(name) <= 253 do
    label = ~r/\A[[:alnum:]_]([[:alnum:]_-]{0,61}[[:alnum:]_])?\z/
    name |> String.split(".") |> Enum.all?(&(&1 =~ label))
  end

  def dns?(_name), do: false

  # These are parsed as dhcp-host keywords or lease times, not hostnames.
  @spec hostname!(String.t()) :: String.t()
  def hostname!(hostname) when hostname in ["ignore", "infinite"],
    do: raise(ArgumentError, "Invalid hostname #{inspect(hostname)}")

  def hostname!(hostname) when is_binary(hostname) and byte_size(hostname) <= 63 do
    if hostname =~ ~r/\A[[:alnum:]]([[:alnum:]-]*[[:alnum:]])?\z/ and
         not (hostname =~ ~r/\A\d+[smhdwSMHDW]?\z/) do
      hostname
    else
      raise ArgumentError, "Invalid hostname #{inspect(hostname)}"
    end
  end

  def hostname!(hostname), do: raise(ArgumentError, "Invalid hostname #{inspect(hostname)}")
end
