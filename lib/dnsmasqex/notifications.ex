# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.Notifications do
  @moduledoc false

  alias Dnsmasqex.Event
  alias Dnsmasqex.Leases
  alias VintageNet.IP

  @typedoc false
  @type context :: %{
          ifname: VintageNet.ifname(),
          address: :inet.ip4_address(),
          prefix_length: VintageNet.prefix_length(),
          lease_path: Path.t()
        }

  @lease_actions ["add", "old", "del"]

  @doc """
  Publish an event reported by dnsmasq's script
  """
  @spec dispatch([String.t()], %{optional(String.t()) => String.t()}, context()) :: :ok
  def dispatch(args, env, context) do
    event = Event.new(args, env)

    if on_subnet?(event, context) do
      PropertyTable.put(VintageNet, event_property(context.ifname), event)
    end

    if event.name in @lease_actions do
      Leases.update(context.ifname, context.lease_path)
    end

    :ok
  end

  @doc """
  Remove the published leases, event and runtime values
  """
  @spec clear(VintageNet.ifname()) :: :ok
  def clear(ifname) do
    Leases.clear(ifname)
    PropertyTable.delete_matches(VintageNet, ["interface", ifname, "dnsmasq"])
  end

  # dnsmasq reports neighbors on every interface, not only its own
  defp on_subnet?(%Event{name: name, ip: ip}, context) when name in ["arp-add", "arp-del"] do
    case IP.ip_to_tuple(ip) do
      {:ok, {_, _, _, _} = ip} ->
        IP.to_subnet(ip, context.prefix_length) ==
          IP.to_subnet(context.address, context.prefix_length)

      _ ->
        false
    end
  end

  defp on_subnet?(_event, _context), do: true

  defp event_property(ifname), do: ["interface", ifname, "dnsmasq", "event"]
end
