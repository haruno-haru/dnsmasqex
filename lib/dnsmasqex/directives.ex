# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.Directives do
  @moduledoc """
  Advanced options supported by the installed, unmodified dnsmasq.

  Set `:directives` to a keyword list using underscores in option names:

      directives: [
        cache_size: 1000,
        stop_dns_rebind: true,
        dhcp_vendorclass: "set:esp,ESP",
        dhcp_option_force: "tag:esp,option:ntp-server,192.0.2.1",
        ptr_record: "1.2.0.192.in-addr.arpa,gateway.lan"
      ]

  Repeat a key for repeatable native options. Flags accept booleans. Integer
  options accept integers; compound values use dnsmasq's documented grammar.
  Each value is confined to one directive. Unknown options and directives
  owning process lifecycle, generated paths, scripts or interface binding are
  rejected. The installed binary checks syntax and build support before use.

  Updating this list at runtime restarts dnsmasq after validating the complete
  prospective configuration. It is not a HUP-only update. Leases survive when
  their configured file survives. Prefer `:upstreams`, `:dhcp_hosts`,
  `:dhcp_options` and the existing runtime APIs for reloadable data.

  `supported/0` lists accepted names and types. Newer options require a binary
  that implements them; the library does not silently ignore unsupported ones.
  """

  @flags ~w(
    no_poll bogus_priv selfmx filterwin2k filter_a filter_aaaa strict_order localmx
    no_negcache no_round_robin no_0x20_encode do_0x20_encode domain_needed read_ethers
    dhcp_authoritative localise_queries no_ping script_on_renewal clear_on_reload tftp_secure
    tftp_no_fail tftp_lowercase tftp_single_port tftp_no_blocksize log_dhcp dhcp_no_override
    stop_dns_rebind all_servers dhcp_fqdn rebind_localhost_ok strip_mac strip_subnet
    proxy_dnssec dhcp_sequential_ip conntrack dhcp_client_update enable_ra dnssec dnssec_debug
    dnssec_no_timecheck quiet_dhcp quiet_dhcp6 quiet_ra dns_loop_detect script_arp
    dhcp_rapid_commit dhcp_ignore_clid log_debug quiet_tftp no_ident log_malloc
  )a

  @optional ~w(
    log_queries user group resolv_file cache_size local_service enable_dbus enable_ubus
    bootp_dynamic dhcp_ignore_names enable_tftp tftp_unique_root log_async dhcp_broadcast
    dhcp_alternate_port dhcp_proxy dhcp_generate_names add_mac add_subnet
    connmark_allowlist_enable dnssec_check_unsigned umbrella fast_dns_retry use_stale_cache
    leasequery
  )a

  @values ~w(
    mx_host mx_target port dhcp_host dhcp_range dhcp_option dhcp_boot domain domain_suffix
    bogus_nxdomain ignore_address filter_rr server rev_server local address local_ttl cache_rr
    addn_hosts hostsdir query_port no_dhcp_interface no_dhcpv4_interface no_dhcpv6_interface
    dhcp_lease_max alias dhcp_vendorclass dhcp_userclass dhcp_ignore edns_packet_max srv_host
    txt_record caa_record dns_rr dhcp_mac dns_forward_max tftp_root tftp_max tftp_mtu
    ptr_record naptr_record bridge_interface shared_network dhcp_option_force dhcp_option_pxe
    dhcp_circuitid dhcp_remoteid dhcp_subscrid dhcp_pxe_vendor interface_name dhcp_hostsdir
    dhcp_optsdir tftp_port_range rebind_domain_ok dhcp_match dhcp_name_match neg_ttl max_ttl
    min_cache_ttl max_cache_ttl dhcp_scriptuser min_port max_port cname pxe_prompt pxe_service
    tag_if add_cpe_id dhcp_duid host_record auth_zone auth_server auth_ttl auth_soa
    auth_sec_servers auth_peer ipset nftset connmark_allowlist synth_domain trust_anchor
    dnssec_timestamp dnssec_limits dhcp_relay dhcp_split_relay ra_param dhcp_ttl
    dhcp_reply_delay dumpfile dumpmask dynamic_host port_limit max_tcp_connections
  )a

  @integers ~w(cache_size port query_port local_ttl neg_ttl max_ttl min_cache_ttl
    max_cache_ttl dhcp_ttl auth_ttl dhcp_lease_max edns_packet_max dns_forward_max
    min_port max_port port_limit max_tcp_connections tftp_max tftp_mtu
    dhcp_reply_delay)a
  @positive ~w(dns_forward_max max_tcp_connections port_limit tftp_max tftp_mtu)a
  @ports ~w(port query_port min_port max_port)a
  @names %{filter_a: "filter-A", filter_aaaa: "filter-AAAA"}

  @spec supported() :: %{atom() => :boolean | :optional | :integer | :value}
  def supported() do
    Map.new(@flags, &{&1, :boolean})
    |> Map.merge(Map.new(@optional, &{&1, :optional}))
    |> Map.merge(Map.new(@values, &{&1, :value}))
    |> Map.merge(Map.new(@integers, &{&1, :integer}))
  end

  @spec normalize(keyword()) :: keyword()
  def normalize(options) when is_list(options) do
    unless Keyword.keyword?(options),
      do: raise(ArgumentError, "dnsmasq :directives must be a keyword list")

    Enum.map(options, fn {key, value} ->
      value = validate(key, value)
      _ = line(key, value)
      {key, value}
    end)
  end

  def normalize(_options),
    do: raise(ArgumentError, "dnsmasq :directives must be a keyword list")

  defp validate(key, value) when key in @integers and is_integer(value) do
    maximum = if key in @ports, do: 65_535, else: 0x7FFFFFFF
    minimum = if key in @positive, do: 1, else: 0

    if value < minimum or value > maximum,
      do: raise(ArgumentError, "Invalid dnsmasq #{key}: #{inspect(value)}")

    value
  end

  defp validate(key, value) when key in @flags and is_boolean(value), do: value

  defp validate(key, value) when key in @optional and key not in @integers and is_boolean(value),
    do: value

  defp validate(key, value)
       when key in @optional and key not in @integers and is_integer(value) and value >= 0,
       do: value

  defp validate(key, value)
       when (key in @values or key in @optional) and key not in @integers and is_binary(value) do
    if value == "" or String.trim(value) != value or Regex.match?(~r/[\x00-\x1f\x7f]/, value),
      do: raise(ArgumentError, "Invalid dnsmasq #{key} value")

    value
  end

  defp validate(key, value),
    do: raise(ArgumentError, "Unsupported dnsmasq directive or value: #{inspect({key, value})}")

  @spec lines(keyword()) :: [String.t()]
  def lines(options), do: for({key, value} <- options, value != false, do: line(key, value))

  defp line(_key, false), do: ""

  defp line(key, value) do
    name = Map.get(@names, key, key |> Atom.to_string() |> String.replace("_", "-"))
    line = if value == true, do: name, else: name <> "=" <> to_string(value)

    if byte_size(line) > 1024,
      do: raise(ArgumentError, "dnsmasq directive exceeds 1024-byte line limit")

    line
  end

  @spec enabled?(keyword(), atom()) :: boolean()
  def enabled?(options, key),
    do: Enum.any?(options, fn {name, value} -> name == key and value != false end)

  @spec ra?(keyword()) :: boolean()
  def ra?(options) do
    enabled?(options, :enable_ra) or
      Enum.any?(Keyword.get_values(options, :dhcp_range), fn range ->
        Enum.any?(
          String.split(range, ","),
          &(&1 in ["slaac", "ra-only", "ra-stateless", "ra-names", "ra-advrouter"])
        )
      end)
  end

  @spec dhcp?(keyword()) :: boolean()
  def dhcp?(options) do
    Enum.any?(options, fn {key, value} ->
      value != false and
        (String.starts_with?(Atom.to_string(key), "dhcp_") or
           key in [
             :enable_ra,
             :ra_param,
             :bootp_dynamic,
             :pxe_service,
             :pxe_prompt,
             :read_ethers,
             :leasequery
           ])
    end)
  end

  @spec features(keyword()) :: [atom()]
  def features(options) do
    checks = [
      dnssec: [:dnssec, :trust_anchor],
      auth: [:auth_zone, :auth_server],
      tftp: [:enable_tftp],
      ipset: [:ipset],
      nftset: [:nftset],
      conntrack: [:conntrack, :connmark_allowlist_enable, :connmark_allowlist],
      dbus: [:enable_dbus],
      ubus: [:enable_ubus],
      inotify: [:hostsdir, :dhcp_hostsdir, :dhcp_optsdir],
      dumpfile: [:dumpfile],
      loop_detect: [:dns_loop_detect]
    ]

    for {feature, keys} <- checks, Enum.any?(keys, &enabled?(options, &1)), do: feature
  end
end
