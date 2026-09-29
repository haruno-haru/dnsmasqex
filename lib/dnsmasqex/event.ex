# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.Event do
  @moduledoc """
  dnsmasq events

  `:name` is the action dnsmasq reports: `"add"`, `"old"` and `"del"` for DHCP
  leases, `"arp-add"` and `"arp-del"` for neighbors on the interface's subnet.
  TFTP events include file metadata, and relay snoop events include their
  interface and client address. Other actions only have a `:name`. Fields are `nil` when dnsmasq
  doesn't know them.

  * `:id` - an integer unique to each published event within the current BEAM;
    `nil` for events returned by `new/2` before publication
  * `:mac` - the client's MAC address
  * `:ip` - the client's IP address
  * `:hostname` - the client's hostname
  * `:supplied_hostname` - the hostname the client asked for
  * `:old_hostname` - the hostname that was removed from the lease
  * `:client_id` - the DHCP client identifier
  * `:duid` - the DHCPv6 client DUID, also exposed as `:client_id`
  * `:iaid` - the DHCPv6 IAID as a string, prefixed by `T` for temporary addresses
  * `:server_duid` - the DHCPv6 server DUID
  * `:interface` - the interface reported for a DHCP lease
  * `:vendor_class` - the DHCP vendor class
  * `:vendor_class_id` and `:vendor_classes` - DHCPv6 vendor enterprise ID and classes
  * `:tags` - the tags set during the DHCP transaction
  * `:time_remaining` - seconds until the lease expires
  * `:lease_expires` - Unix expiry on builds with a real-time clock
  * `:lease_length` - recorded duration on `no-RTC` builds
  * `:domain` - the lease's domain
  * `:data_missing` - request metadata was not retained across a restart
  * `:relay_address`, `:circuit_id`, `:remote_id`, `:subscriber_id` - relay metadata
  * `:file_name`, `:file_size` - completed TFTP transfer path and byte count
  * `:delegated_prefix` - observed prefix in CIDR notation for a relay snoop event
  * `:requested_options` - the DHCP option numbers the client asked for, in
    its order
  * `:user_classes` - the client's DHCP user classes
  * `:mud_url` - the client's Manufacturer Usage Description URL
  * `:cpewan` - the TR-111 `:oui`, `:serial` and `:class` of a CPE client

  dnsmasq only knows the request fields for leases it handled since it started.
  The `"old"` events it reports on startup and reload for other leases leave
  them `nil`.

  ## Examples

      iex> Dnsmasqex.Event.new(["add", "aa:bb:cc:dd:ee:ff", "192.168.24.10", "printer"], %{"DNSMASQ_TIME_REMAINING" => "3600", "DNSMASQ_TAGS" => "eth1 known", "DNSMASQ_REQUESTED_OPTIONS" => "1,3,6,15"})
      %Dnsmasqex.Event{
        name: "add",
        mac: "aa:bb:cc:dd:ee:ff",
        ip: "192.168.24.10",
        hostname: "printer",
        tags: ["eth1", "known"],
        time_remaining: 3600,
        requested_options: [1, 3, 6, 15]
      }

      iex> Dnsmasqex.Event.new(["arp-del", "aa:bb:cc:dd:ee:ff", "192.168.24.10"], %{})
      %Dnsmasqex.Event{name: "arp-del", mac: "aa:bb:cc:dd:ee:ff", ip: "192.168.24.10"}

      iex> Dnsmasqex.Event.new(["tftp", "1024", "192.168.24.10", "/boot/file"], %{})
      %Dnsmasqex.Event{name: "tftp", file_size: 1024, ip: "192.168.24.10", file_name: "/boot/file"}
  """

  alias VintageNet.IP

  @enforce_keys [:name]
  # Keep the published protocol fields compatible with 0.1.2.
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct [
    :name,
    :id,
    :mac,
    :ip,
    :hostname,
    :supplied_hostname,
    :old_hostname,
    :client_id,
    :duid,
    :iaid,
    :server_duid,
    :interface,
    :vendor_class,
    :vendor_class_id,
    :vendor_classes,
    :tags,
    :time_remaining,
    :lease_expires,
    :lease_length,
    :domain,
    :data_missing,
    :relay_address,
    :circuit_id,
    :remote_id,
    :subscriber_id,
    :file_name,
    :file_size,
    :delegated_prefix,
    :requested_options,
    :user_classes,
    :mud_url,
    :cpewan
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          id: pos_integer() | nil,
          mac: String.t() | nil,
          ip: String.t() | nil,
          hostname: String.t() | nil,
          supplied_hostname: String.t() | nil,
          old_hostname: String.t() | nil,
          client_id: String.t() | nil,
          duid: String.t() | nil,
          iaid: String.t() | nil,
          server_duid: String.t() | nil,
          interface: String.t() | nil,
          vendor_class: String.t() | nil,
          vendor_class_id: String.t() | nil,
          vendor_classes: [String.t()] | nil,
          tags: [String.t()] | nil,
          time_remaining: non_neg_integer() | nil,
          lease_expires: non_neg_integer() | nil,
          lease_length: non_neg_integer() | nil,
          domain: String.t() | nil,
          data_missing: boolean() | nil,
          relay_address: String.t() | nil,
          circuit_id: String.t() | nil,
          remote_id: String.t() | nil,
          subscriber_id: String.t() | nil,
          file_name: String.t() | nil,
          file_size: non_neg_integer() | nil,
          delegated_prefix: String.t() | nil,
          requested_options: [0..65_535] | nil,
          user_classes: [String.t()] | nil,
          mud_url: String.t() | nil,
          cpewan: cpewan() | nil
        }

  @type cpewan :: %{oui: String.t() | nil, serial: String.t() | nil, class: String.t() | nil}

  @doc """
  Create an event from the arguments and environment of dnsmasq's script
  """
  @spec new([String.t()], %{optional(String.t()) => String.t()}) :: t()
  def new([name, mac, ip | _args], _env) when name in ["arp-add", "arp-del"],
    do: %__MODULE__{name: name, mac: mac, ip: ip}

  def new(["tftp", size, ip, path], _env),
    do: %__MODULE__{name: "tftp", file_size: time_remaining(size), ip: ip, file_name: path}

  def new(["relay-snoop", interface, ip | prefix], _env),
    do: %__MODULE__{
      name: "relay-snoop",
      interface: interface,
      ip: ip,
      delegated_prefix: List.first(prefix)
    }

  def new([name, identity, ip | hostname], env) when name in ["add", "old", "del"] do
    event = %__MODULE__{
      name: name,
      ip: ip,
      hostname: List.first(hostname),
      supplied_hostname: env["DNSMASQ_SUPPLIED_HOSTNAME"],
      old_hostname: env["DNSMASQ_OLD_HOSTNAME"],
      interface: env["DNSMASQ_INTERFACE"],
      tags: tags(env["DNSMASQ_TAGS"]),
      time_remaining: time_remaining(env["DNSMASQ_TIME_REMAINING"]),
      lease_expires: time_remaining(env["DNSMASQ_LEASE_EXPIRES"]),
      lease_length: time_remaining(env["DNSMASQ_LEASE_LENGTH"]),
      domain: env["DNSMASQ_DOMAIN"],
      data_missing: if(env["DNSMASQ_DATA_MISSING"], do: env["DNSMASQ_DATA_MISSING"] == "1"),
      relay_address: env["DNSMASQ_RELAY_ADDRESS"],
      circuit_id: env["DNSMASQ_CIRCUIT_ID"],
      remote_id: env["DNSMASQ_REMOTE_ID"],
      subscriber_id: env["DNSMASQ_SUBSCRIBER_ID"],
      user_classes: numbered_classes(env, "DNSMASQ_USER_CLASS"),
      mud_url: env["DNSMASQ_MUD_URL"]
    }

    case String.valid?(ip) && IP.ip_to_tuple(ip) do
      {:ok, {_, _, _, _}} ->
        %{
          event
          | mac: identity,
            client_id: env["DNSMASQ_CLIENT_ID"],
            vendor_class: env["DNSMASQ_VENDOR_CLASS"],
            requested_options: requested_options(env["DNSMASQ_REQUESTED_OPTIONS"], 255),
            cpewan: cpewan(env)
        }

      {:ok, {_, _, _, _, _, _, _, _}} ->
        %{
          event
          | mac: env["DNSMASQ_MAC"],
            client_id: identity,
            duid: identity,
            iaid: env["DNSMASQ_IAID"],
            server_duid: env["DNSMASQ_SERVER_DUID"],
            vendor_class_id: env["DNSMASQ_VENDOR_CLASS_ID"],
            vendor_classes: numbered_classes(env, "DNSMASQ_VENDOR_CLASS"),
            requested_options: requested_options(env["DNSMASQ_REQUESTED_OPTIONS"], 65_535)
        }

      _ ->
        %__MODULE__{name: name}
    end
  end

  def new([name | _args], _env), do: %__MODULE__{name: name}

  defp tags(nil), do: nil
  defp tags(tags), do: String.split(tags)

  defp requested_options(nil, _maximum), do: nil

  defp requested_options(options, maximum) do
    numbers = options |> String.split(",") |> Enum.map(&Integer.parse/1)

    if Enum.all?(numbers, &match?({number, ""} when number >= 0 and number <= maximum, &1)),
      do: Enum.map(numbers, &elem(&1, 0))
  end

  defp numbered_classes(env, prefix) do
    classes =
      Stream.iterate(0, &(&1 + 1))
      |> Stream.map(&env["#{prefix}#{&1}"])
      |> Enum.take_while(& &1)

    if classes != [], do: classes
  end

  defp cpewan(env) do
    cpewan = %{
      oui: env["DNSMASQ_CPEWAN_OUI"],
      serial: env["DNSMASQ_CPEWAN_SERIAL"],
      class: env["DNSMASQ_CPEWAN_CLASS"]
    }

    if Enum.any?(Map.values(cpewan)), do: cpewan
  end

  defp time_remaining(nil), do: nil

  defp time_remaining(seconds) do
    case Integer.parse(seconds) do
      {seconds, ""} when seconds >= 0 -> seconds
      _ -> nil
    end
  end
end
