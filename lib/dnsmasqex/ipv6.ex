# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.IPv6 do
  @moduledoc false

  alias Dnsmasqex.Config.Names
  alias Dnsmasqex.Directives
  alias VintageNet.Interface.RawConfig
  alias VintageNet.IP

  @modes [:stateful, :static, :slaac, :stateless, :ra_only]
  @ra_modes [:slaac, :stateless, :ra_only]

  @type interface :: %{
          required(:method) => :static,
          required(:address) => :inet.ip6_address(),
          required(:prefix_length) => 1..128,
          optional(:addresses) => [%{address: :inet.ip6_address(), prefix_length: 1..128}]
        }

  @spec normalize(map()) :: map()
  def normalize(
        %{ipv6: %{method: :static, address: address, prefix_length: prefix} = ipv6} = config
      )
      when prefix in 1..128 do
    if Map.keys(ipv6) -- [:method, :address, :prefix_length, :addresses] != [],
      do: raise(ArgumentError, "Invalid IPv6 interface configuration: unsupported fields")

    ipv6 = %{ipv6 | address: unicast!(address)}

    ipv6 =
      if Map.has_key?(ipv6, :addresses),
        do: Map.update!(ipv6, :addresses, &additional_addresses!/1),
        else: ipv6

    addresses = [ipv6.address | Enum.map(Map.get(ipv6, :addresses, []), & &1.address)]

    if Enum.uniq(addresses) != addresses,
      do: raise(ArgumentError, "Duplicate IPv6 interface address")

    %{config | ipv6: ipv6}
  end

  def normalize(%{ipv6: %{method: :manual} = ipv6} = config) when map_size(ipv6) == 1,
    do: config

  def normalize(%{ipv6: %{method: :disabled} = ipv6} = config) when map_size(ipv6) == 1,
    do: config

  def normalize(%{ipv6: ipv6}),
    do:
      raise(
        ArgumentError,
        "Invalid IPv6 interface configuration; expected :static with :address and :prefix_length, :manual or :disabled, got: #{inspect(ipv6)}"
      )

  def normalize(config), do: config

  defp additional_addresses!(addresses) when is_list(addresses) do
    Enum.map(addresses, fn
      %{address: address, prefix_length: prefix} = entry
      when prefix in 1..128 and map_size(entry) == 2 ->
        %{entry | address: unicast!(address)}

      value ->
        raise ArgumentError, "Invalid additional IPv6 address #{inspect(value)}"
    end)
  end

  defp additional_addresses!(_addresses),
    do: raise(ArgumentError, "IPv6 :addresses must be a list")

  @spec unmanaged?(map()) :: boolean()
  def unmanaged?(config), do: match?(%{ipv6: %{method: :manual}}, config)

  @spec interfaces(map()) :: [map()]
  def interfaces(config) do
    case interface(config) do
      nil -> []
      ipv6 -> [Map.take(ipv6, [:address, :prefix_length]) | Map.get(ipv6, :addresses, [])]
    end
  end

  @spec native_ranges?(map()) :: boolean()
  def native_ranges?(dnsmasq), do: native_ranges(dnsmasq) != []

  defp native_ranges(dnsmasq),
    do: Directives.ranges(Map.get(dnsmasq, :directives, []), :inet6)

  defp ipv6_address?(value),
    do:
      String.contains?(value, ":") and
        match?({:ok, _}, :inet.parse_ipv6_address(String.to_charlist(value)))

  @spec interface(map()) :: interface() | nil
  def interface(%{ipv6: %{method: :static} = ipv6}), do: ipv6
  def interface(_config), do: nil

  @spec normalize_dnsmasq(map(), interface() | nil) :: map()
  def normalize_dnsmasq(dnsmasq, ipv6) do
    dnsmasq =
      dnsmasq
      |> Map.update(:static_leases6, [], &normalize_leases(&1, ipv6))
      |> Map.update(:options6, %{}, &normalize_options/1)

    requested? =
      Map.has_key?(dnsmasq, :dhcpv6) or dnsmasq.static_leases6 != [] or
        dnsmasq.options6 != %{} or Map.get(dnsmasq, :enable_ra, false) != false or
        Map.has_key?(dnsmasq, :ra_lifetime)

    if requested? and is_nil(ipv6),
      do: raise(ArgumentError, "dnsmasq IPv6 services require a static :ipv6 interface")

    dnsmasq =
      if dnsmasq.static_leases6 != [] and
           not Directives.enabled?(Map.get(dnsmasq, :directives, []), :dhcp_range),
         do: Map.put_new(dnsmasq, :dhcpv6, %{mode: :static}),
         else: dnsmasq

    normalize_services(dnsmasq, ipv6)
  end

  defp normalize_services(dnsmasq, ipv6) do
    dnsmasq =
      case dnsmasq do
        %{dhcpv6: range} -> %{dnsmasq | dhcpv6: normalize_range(range, ipv6)}
        %{} -> dnsmasq
      end

    check_ra(dnsmasq, ipv6)

    if dnsmasq.static_leases6 != [] and not dhcp_enabled?(dnsmasq),
      do: raise(ArgumentError, "IPv6 static leases need stateful DHCPv6")

    if dnsmasq.options6 != %{} and not Map.has_key?(dnsmasq, :dhcpv6) and
         not native_ranges?(dnsmasq),
       do: raise(ArgumentError, "dnsmasq :options6 requires :dhcpv6")

    dnsmasq
  end

  defp check_ra(dnsmasq, ipv6) do
    enable_ra = Map.get(dnsmasq, :enable_ra, false)

    if not is_boolean(enable_ra), do: raise(ArgumentError, "dnsmasq :enable_ra must be a boolean")

    ra? = enable_ra or get_in(dnsmasq, [:dhcpv6, :mode]) in @ra_modes

    if ra? and (is_nil(ipv6) or ipv6.prefix_length != 64),
      do: raise(ArgumentError, "dnsmasq router advertisements require an IPv6 /64")

    if enable_ra and not Map.has_key?(dnsmasq, :dhcpv6),
      do:
        raise(ArgumentError, "dnsmasq :enable_ra requires :dhcpv6; use mode: :ra_only for SLAAC")

    check_ra_lifetime(dnsmasq, ra?)
  end

  defp check_ra_lifetime(%{ra_lifetime: lifetime}, true)
       when lifetime === 0 or lifetime in 600..9000,
       do: :ok

  defp check_ra_lifetime(%{ra_lifetime: _lifetime}, _ra?),
    do:
      raise(ArgumentError, "dnsmasq :ra_lifetime requires RA and must be 0 or 600..9000 seconds")

  defp check_ra_lifetime(_dnsmasq, _ra?), do: :ok

  defp normalize_range(range, ipv6) when is_map(range) do
    unknown = Map.keys(range) -- [:start, :end, :mode, :lease_time]
    mode = Map.get(range, :mode, :stateful)

    if unknown != [] or mode not in @modes,
      do: raise(ArgumentError, "Invalid dnsmasq :dhcpv6 #{inspect(range)}")

    if ipv6.prefix_length < 64,
      do: raise(ArgumentError, "dnsmasq DHCPv6 requires a prefix length of 64..128")

    range = Map.put(range, :mode, mode)

    range =
      if mode in [:stateful, :slaac] do
        normalize_pool(range, ipv6)
      else
        if Map.has_key?(range, :start) or Map.has_key?(range, :end),
          do: raise(ArgumentError, "dnsmasq #{inspect(mode)} doesn't allocate an address pool")

        range
      end

    case range do
      %{lease_time: time} -> %{range | lease_time: lease_time!(time)}
      %{} -> range
    end
  end

  defp normalize_range(range, _ipv6),
    do: raise(ArgumentError, "Expected a map for dnsmasq :dhcpv6, got: #{inspect(range)}")

  defp normalize_pool(%{start: first, end: last} = range, ipv6) do
    first = lease_ip!(first, ipv6)
    last = lease_ip!(last, ipv6)
    prefix = IP.to_subnet(ipv6.address, ipv6.prefix_length)

    if Enum.any?([first, last], &(IP.to_subnet(&1, ipv6.prefix_length) != prefix)),
      do:
        raise(
          ArgumentError,
          "The :dhcpv6 pool must use the primary prefix; use native ranges for multiple prefixes"
        )

    if first > last or (first <= ipv6.address and ipv6.address <= last),
      do: raise(ArgumentError, "DHCPv6 range must be ordered and exclude the interface's address")

    %{range | start: first, end: last}
  end

  defp normalize_pool(_range, _ipv6),
    do: raise(ArgumentError, "dnsmasq DHCPv6 needs both :start and :end")

  defp normalize_leases(leases, ipv6) when is_list(leases) do
    leases = Enum.map(leases, &normalize_lease(&1, ipv6))

    Enum.each([:duid, :ip], fn key ->
      values = Enum.map(leases, &Map.fetch!(&1, key))

      if Enum.uniq(values) != values,
        do: raise(ArgumentError, "Duplicate IPv6 static lease #{key}")
    end)

    leases
  end

  defp normalize_leases(leases, _ipv6),
    do: raise(ArgumentError, "Expected a list for :static_leases6, got: #{inspect(leases)}")

  defp normalize_lease(%{duid: _duid, ip: _ip} = lease, %{method: :static} = ipv6) do
    if Map.keys(lease) -- [:duid, :ip, :hostname, :lease_time] != [],
      do: raise(ArgumentError, "Invalid IPv6 static lease #{inspect(lease)}")

    Map.new(lease, fn
      {:duid, duid} -> {:duid, duid!(duid)}
      {:ip, ip} -> {:ip, lease_ip!(ip, ipv6)}
      {:hostname, hostname} -> {:hostname, Names.hostname!(hostname)}
      {:lease_time, time} -> {:lease_time, lease_time!(time)}
    end)
  end

  defp normalize_lease(lease, _ipv6),
    do:
      raise(
        ArgumentError,
        "IPv6 static lease needs :duid, :ip and a static IPv6 interface: #{inspect(lease)}"
      )

  defp duid!(duid) when is_binary(duid) do
    if duid =~ ~r/\A[[:xdigit:]]{2}(?::[[:xdigit:]]{2}){2,129}\z/,
      do: String.downcase(duid),
      else: raise(ArgumentError, "Invalid DHCPv6 DUID #{inspect(duid)}")
  end

  defp duid!(duid), do: raise(ArgumentError, "Invalid DHCPv6 DUID #{inspect(duid)}")

  defp lease_time!(:infinite), do: :infinite
  defp lease_time!(seconds) when seconds in 120..0xFFFFFFFE, do: seconds
  defp lease_time!(time), do: raise(ArgumentError, "Invalid DHCPv6 lease time #{inspect(time)}")

  defp lease_ip!(ip, ipv6) do
    ip = unicast!(ip)
    subnets = [ipv6 | Map.get(ipv6, :addresses, [])]

    if Enum.any?(subnets, &(&1.address == ip)) or not Enum.any?(subnets, &lease_subnet?(ip, &1)),
      do:
        raise(
          ArgumentError,
          "IPv6 lease must be on the interface's subnet and not its address or subnet-router anycast address"
        )

    ip
  end

  defp lease_subnet?(ip, subnet) do
    network = IP.to_subnet(subnet.address, subnet.prefix_length)
    IP.to_subnet(ip, subnet.prefix_length) == network and ip != network
  end

  defp normalize_options(options) when is_map(options) do
    numbers = Enum.map(options, fn {key, _value} -> option_number(key) end)

    if length(Enum.uniq(numbers)) != length(numbers),
      do: raise(ArgumentError, "Duplicate DHCPv6 option aliases")

    Map.new(options, fn option ->
      normalized = normalize_option(option)
      _ = line!(option_line(normalized))
      normalized
    end)
  end

  defp normalize_options(options),
    do: raise(ArgumentError, "Expected a map for :options6, got: #{inspect(options)}")

  @spec option_number(atom() | integer()) :: atom() | integer()
  def option_number(:dns), do: 23
  def option_number(:search), do: 24
  def option_number(:ntp), do: 56
  def option_number(key), do: key

  defp normalize_option({name, ips}) when name in [:dns, :ntp] and not is_nil(ips),
    do: {name, Enum.map(List.wrap(ips), &address!/1)}

  defp normalize_option({:search, names}) when not is_nil(names),
    do: {:search, Enum.map(List.wrap(names), &Names.dns!/1)}

  defp normalize_option({number, value}) when number in 1..65_535 and is_binary(value) do
    if String.contains?(value, ["\n", "\r", "\0"]),
      do: raise(ArgumentError, "Invalid DHCPv6 option #{number}")

    {number, value}
  end

  defp normalize_option(option),
    do: raise(ArgumentError, "Invalid DHCPv6 option #{inspect(option)}")

  defp address!(ip) do
    with {:ok, address} when tuple_size(address) == 8 <- IP.ip_to_tuple(ip),
         true <- Enum.all?(Tuple.to_list(address), &is_integer/1) do
      address
    else
      _ -> raise ArgumentError, "Invalid IPv6 address #{inspect(ip)}"
    end
  end

  defp unicast!(ip) do
    address = address!(ip)
    first = elem(address, 0)

    if address in [{0, 0, 0, 0, 0, 0, 0, 0}, {0, 0, 0, 0, 0, 0, 0, 1}] or
         first in 0xFE80..0xFFFF or match?({0, 0, 0, 0, 0, 0xFFFF, _, _}, address),
       do:
         raise(
           ArgumentError,
           "Expected a global or unique-local IPv6 address, got: #{inspect(ip)}"
         )

    address
  end

  @spec add_config(RawConfig.t(), map()) :: RawConfig.t()
  def add_config(raw_config, %{ipv6: %{method: :static}} = config) do
    addresses =
      for ipv6 <- interfaces(config),
          do: [IP.cidr_to_string(ipv6.address, ipv6.prefix_length), "dev", raw_config.ifname]

    %{
      raw_config
      | up_cmds:
          raw_config.up_cmds ++ Enum.map(addresses, &{:run, "ip", ["-6", "addr", "add" | &1]}),
        down_cmds:
          Enum.map(addresses, &{:run_ignore_errors, "ip", ["-6", "addr", "del" | &1]}) ++
            raw_config.down_cmds
    }
  end

  def add_config(raw_config, _config), do: raw_config

  @spec dhcp_enabled?(map()) :: boolean()
  def dhcp_enabled?(%{dhcpv6: %{mode: mode}}), do: mode in [:stateful, :static, :slaac]

  def dhcp_enabled?(dnsmasq) do
    Enum.any?(native_ranges(dnsmasq), fn fields ->
      "ra-stateless" not in fields and
        ("static" in fields or (match?([_, _ | _], fields) and ipv6_address?(Enum.at(fields, 1))))
    end)
  end

  @spec ra_enabled?(map()) :: boolean()
  def ra_enabled?(dnsmasq),
    do:
      Map.get(dnsmasq, :enable_ra, false) or get_in(dnsmasq, [:dhcpv6, :mode]) in @ra_modes or
        Directives.ra?(Map.get(dnsmasq, :directives, []))

  @spec config_lines(map(), interface() | nil, String.t()) :: [String.t()]
  def config_lines(%{dhcpv6: range} = dnsmasq, ipv6, ifname) do
    fields =
      case range do
        %{mode: :stateful, start: first, end: last} ->
          [IP.ip_to_string(first), IP.ip_to_string(last)]

        %{mode: :slaac, start: first, end: last} ->
          [IP.ip_to_string(first), IP.ip_to_string(last), "slaac"]

        %{mode: mode} ->
          [IP.ip_to_string(IP.to_subnet(ipv6.address, ipv6.prefix_length)), mode_string(mode)]
      end

    fields = fields ++ [Integer.to_string(ipv6.prefix_length)] ++ lease_time(range[:lease_time])
    ra = if Map.get(dnsmasq, :enable_ra, false), do: ["enable-ra"], else: []

    params =
      if Map.has_key?(dnsmasq, :ra_lifetime),
        do: ["ra-param=#{ifname},0,#{dnsmasq.ra_lifetime}"],
        else: []

    ["dhcp-range=" <> Enum.join(fields, ",")] ++ ra ++ params
  end

  def config_lines(_dnsmasq, _ipv6, _ifname), do: []

  defp mode_string(:static), do: "static"
  defp mode_string(:stateless), do: "ra-stateless"
  defp mode_string(:ra_only), do: "ra-only"

  @spec hosts_contents([map()]) :: String.t()
  def hosts_contents(leases) do
    Enum.map_join(leases, fn lease ->
      fields = ["id:#{lease.duid}", "[#{IP.ip_to_string(lease.ip)}]"]
      fields = fields ++ if(lease[:hostname], do: [lease.hostname], else: [])
      line!(Enum.join(fields ++ lease_time(Map.get(lease, :lease_time, :infinite)), ",")) <> "\n"
    end)
  end

  @spec options_contents(map()) :: String.t()
  def options_contents(options),
    do: options |> Enum.sort() |> Enum.map_join(&(option_line(&1) <> "\n"))

  defp option_line({name, values}) when name in [:dns, :ntp] do
    option = if name == :dns, do: "dns-server", else: "ntp-server"
    Enum.join(["option6:#{option}" | Enum.map(values, &"[#{IP.ip_to_string(&1)}]")], ",")
  end

  defp option_line({:search, names}), do: Enum.join(["option6:domain-search" | names], ",")
  defp option_line({number, ""}), do: "option6:#{number}"
  defp option_line({number, value}), do: "option6:#{number},#{value}"

  defp lease_time(nil), do: []
  defp lease_time(:infinite), do: ["infinite"]
  defp lease_time(seconds), do: [Integer.to_string(seconds)]

  defp line!(line) do
    if byte_size(line) > 1024,
      do: raise(ArgumentError, "DHCPv6 configuration exceeds dnsmasq's 1024-byte line limit")

    line
  end
end
