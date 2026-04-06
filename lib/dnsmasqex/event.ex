# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.Event do
  @moduledoc """
  dnsmasq events

  `:name` is the action dnsmasq reports: `"add"`, `"old"` and `"del"` for DHCP
  leases, `"arp-add"` and `"arp-del"` for neighbors on the interface's subnet.
  Other actions only have a `:name`. The remaining fields are `nil` when dnsmasq
  doesn't know them.

  * `:mac` - the client's MAC address
  * `:ip` - the client's IP address
  * `:hostname` - the client's hostname
  * `:supplied_hostname` - the hostname the client asked for
  * `:old_hostname` - the hostname that was removed from the lease
  * `:client_id` - the DHCP client identifier
  * `:vendor_class` - the DHCP vendor class
  * `:tags` - the tags set during the DHCP transaction
  * `:time_remaining` - seconds until the lease expires

  ## Examples

      iex> Dnsmasqex.Event.new(["add", "aa:bb:cc:dd:ee:ff", "192.168.24.10", "printer"], %{"DNSMASQ_TIME_REMAINING" => "3600", "DNSMASQ_TAGS" => "eth1 known"})
      %Dnsmasqex.Event{
        name: "add",
        mac: "aa:bb:cc:dd:ee:ff",
        ip: "192.168.24.10",
        hostname: "printer",
        tags: ["eth1", "known"],
        time_remaining: 3600
      }

      iex> Dnsmasqex.Event.new(["arp-del", "aa:bb:cc:dd:ee:ff", "192.168.24.10"], %{})
      %Dnsmasqex.Event{name: "arp-del", mac: "aa:bb:cc:dd:ee:ff", ip: "192.168.24.10"}

      iex> Dnsmasqex.Event.new(["tftp", "1024", "192.168.24.10", "/boot/file"], %{})
      %Dnsmasqex.Event{name: "tftp"}
  """

  @enforce_keys [:name]
  defstruct [
    :name,
    :mac,
    :ip,
    :hostname,
    :supplied_hostname,
    :old_hostname,
    :client_id,
    :vendor_class,
    :tags,
    :time_remaining
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          mac: String.t() | nil,
          ip: String.t() | nil,
          hostname: String.t() | nil,
          supplied_hostname: String.t() | nil,
          old_hostname: String.t() | nil,
          client_id: String.t() | nil,
          vendor_class: String.t() | nil,
          tags: [String.t()] | nil,
          time_remaining: non_neg_integer() | nil
        }

  @client_actions ["add", "old", "del", "arp-add", "arp-del"]

  @doc """
  Create an event from the arguments and environment of dnsmasq's script
  """
  @spec new([String.t()], %{optional(String.t()) => String.t()}) :: t()
  def new([name, mac, ip | hostname], env) when name in @client_actions do
    %__MODULE__{
      name: name,
      mac: mac,
      ip: ip,
      hostname: List.first(hostname),
      supplied_hostname: env["DNSMASQ_SUPPLIED_HOSTNAME"],
      old_hostname: env["DNSMASQ_OLD_HOSTNAME"],
      client_id: env["DNSMASQ_CLIENT_ID"],
      vendor_class: env["DNSMASQ_VENDOR_CLASS"],
      tags: tags(env["DNSMASQ_TAGS"]),
      time_remaining: time_remaining(env["DNSMASQ_TIME_REMAINING"])
    }
  end

  def new([name | _args], _env), do: %__MODULE__{name: name}

  defp tags(nil), do: nil
  defp tags(tags), do: String.split(tags)

  defp time_remaining(nil), do: nil

  defp time_remaining(seconds) do
    case Integer.parse(seconds) do
      {seconds, ""} when seconds >= 0 -> seconds
      _ -> nil
    end
  end
end
