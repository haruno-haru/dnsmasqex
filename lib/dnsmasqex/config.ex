# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.Config do
  @moduledoc """
  dnsmasq options for a static IPv4 interface

  * `:start` and `:end` - DHCP address range on the interface's subnet. Without
    them, only static leases get addresses, or only DNS runs if there are none
  * `:lease_time` - seconds, from 120 to 4_294_967_294, or `:infinite`
  * `:static_leases` - `{mac, ip}` or `{mac, ip, hostname}` tuples with
    infinite leases, or maps with a `:mac` and any of `:ip`, `:hostname` and
    `:lease_time`. A map lease with an `:ip` is infinite unless it has a
    `:lease_time`, and `%{mac: mac, ignore: true}` never answers that client
  * `:records` - `{name, ip}` pairs for exactly those names, like `:dnsd`
  * `:domain_records` - `{domain, ip}` pairs that also answer every subdomain.
    The domain may use dnsmasq's patterns, such as `"*.example.com"` for only
    the subdomains, or be `"#"` for every name not found elsewhere
  * `:cnames` - `{alias, target}` pairs. dnsmasq only answers them when it
    knows the target from records or DHCP
  * `:srv_records` - `{name, target, port}` or
    `{name, target, port, priority, weight}` tuples. A target of `"."` marks
    the service as unavailable
  * `:txt_records` - `{name, text}` or `{name, [text]}` pairs
  * `:mx_records` - `{name, target}` or `{name, target, preference}` tuples
  * `:options` - a map of DHCP options to send, like `VintageNet.IP.DhcpdConfig`:
    * `:dns`, `:router`, `:ntp` - IP lists. dnsmasq sends its own address as
      the DNS server and router unless they're set; `[]` sends neither
    * `:domain`, `:hostname` - strings
    * `:search` - a list of search domains
    * `:mtu` - an integer
    * `:serverid`, `:subnet` or `:netmask` - accepted when they match the
      interface, since dnsmasq always sends its own
    * integers - option numbers whose value is passed to dnsmasq unmodified,
      so use dnsmasq's format, for example `43 => "4d:53:46:54"`
  * `:name_servers` - upstream DNS servers. Without it, dnsmasq follows the name
    servers VintageNet writes to `/etc/resolv.conf`. `[]` forwards nothing
  * `:forward_domains` - `{domain, servers}` pairs that forward a domain and its
    subdomains to their own servers. `[]` answers them only from local names
  * `:domain` - the local domain. DHCP clients and records without a dot get
    names in it, clients get it as their domain, and its names are never
    forwarded
  * `:nftsets` - `{domains, sets}` pairs that add the addresses dnsmasq
    resolves for the domains to nftables sets, such as
    `{["example.com"], ["inet#filter#allowed"]}`. A set may start with `4#` or
    `6#` to take only that family. Domains include their subdomains; `"#"`
    matches all domains. Wildcards aren't supported. The tables and sets must
    already exist. Needs `nftset` in
    `Dnsmasqex.capabilities/0` and `Dnsmasqex.nftables_available?/0`
  * `:authoritative` - `true` when dnsmasq is the only DHCP server on the
    network, so clients with leases it doesn't know get addresses right away
  * `:lease_path` - an absolute path for the lease file, so leases survive a
    reboot when it's on a persistent filesystem. Defaults to VintageNet's
    `:tmpdir`
  * `:hosts_dir` - an absolute path to a directory of `dhcp-host` files. New
    files are read automatically
  """

  alias VintageNet.Command
  alias VintageNet.Interface.RawConfig
  alias VintageNet.IP
  alias Dnsmasqex.Daemon
  alias Dnsmasqex.Notifications
  alias Dnsmasqex.Server

  @runtime_options [:static_leases, :options, :records]

  @typedoc false
  @type runtime_option :: :static_leases | :options | :records

  @doc """
  Normalize the `:dnsmasq` options
  """
  @spec normalize(map()) :: map()
  def normalize(%{ipv4: %{method: :static} = ipv4, dnsmasq: dnsmasq} = config)
      when is_map(dnsmasq) do
    check_no_busybox_servers(config)
    check_ipv4(ipv4)

    new_dnsmasq =
      dnsmasq
      |> Map.take([
        :start,
        :end,
        :lease_time,
        :static_leases,
        :records,
        :domain_records,
        :cnames,
        :srv_records,
        :txt_records,
        :mx_records,
        :nftsets,
        :options,
        :name_servers,
        :forward_domains,
        :domain,
        :authoritative,
        :lease_path,
        :hosts_dir
      ])
      |> normalize_range(ipv4)
      |> check_lease_time()
      |> check_path(:hosts_dir, "dhcp-hostsdir")
      |> check_path(:lease_path, "dhcp-leasefile")
      |> check_authoritative()
      |> Map.update(:static_leases, [], &normalize_leases(&1, ipv4))
      |> update_list(:records, &normalize_record/1)
      |> update_list(:domain_records, &normalize_domain_record/1)
      |> update_list(:cnames, &normalize_cname/1)
      |> check_cnames()
      |> update_list(:srv_records, &normalize_srv/1)
      |> update_list(:txt_records, &normalize_txt/1)
      |> update_list(:mx_records, &normalize_mx/1)
      |> update_list(:nftsets, &normalize_nftset/1)
      |> Map.update(:options, %{}, &normalize_options(&1, ipv4))
      |> normalize_name_servers()
      |> update_list(:forward_domains, &normalize_forward_domain/1)
      |> normalize_domain()

    %{config | dnsmasq: new_dnsmasq}
  end

  def normalize(%{ipv4: %{method: :static}, dnsmasq: dnsmasq}),
    do: raise(ArgumentError, "Expected a map for :dnsmasq, got: #{inspect(dnsmasq)}")

  def normalize(%{dnsmasq: _not_static} = config), do: Map.drop(config, [:dnsmasq])
  def normalize(config), do: config

  @doc false
  @spec normalize_value(map(), runtime_option(), term()) :: term()
  def normalize_value(%{dnsmasq: dnsmasq} = config, option, value) do
    %{dnsmasq: normalized} = normalize(%{config | dnsmasq: Map.put(dnsmasq, option, value)})
    Map.fetch!(normalized, option)
  end

  defp check_no_busybox_servers(%{dhcpd: _}),
    do: raise(ArgumentError, "Use :dnsmasq instead of :dhcpd with Dnsmasqex")

  defp check_no_busybox_servers(%{dnsd: _}),
    do: raise(ArgumentError, "Use :dnsmasq instead of :dnsd with Dnsmasqex")

  defp check_no_busybox_servers(_config), do: :ok

  defp check_ipv4(%{address: {a, b, c, d}, prefix_length: prefix_length})
       when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 and
              prefix_length in 0..32,
       do: :ok

  defp check_ipv4(ipv4),
    do: raise(ArgumentError, "Invalid static IPv4 configuration #{inspect(ipv4)}")

  defp normalize_range(%{start: first, end: last} = dnsmasq, ipv4) do
    first = subnet_ip!(first, ipv4)
    last = subnet_ip!(last, ipv4)

    if first > last do
      raise ArgumentError, "dnsmasq :start #{IP.ip_to_string(first)} is after :end"
    end

    %{dnsmasq | start: first, end: last}
  end

  defp normalize_range(%{start: _} = dnsmasq, _ipv4),
    do: raise(ArgumentError, "dnsmasq :start needs an :end in #{inspect(dnsmasq)}")

  defp normalize_range(%{end: _} = dnsmasq, _ipv4),
    do: raise(ArgumentError, "dnsmasq :end needs a :start in #{inspect(dnsmasq)}")

  defp normalize_range(dnsmasq, _ipv4), do: dnsmasq

  defp check_lease_time(%{lease_time: lease_time} = dnsmasq),
    do: %{dnsmasq | lease_time: lease_time!(lease_time)}

  defp check_lease_time(dnsmasq), do: dnsmasq

  defp lease_time!(lease_time)
       when lease_time == :infinite or (is_integer(lease_time) and lease_time in 120..0xFFFFFFFE),
       do: lease_time

  defp lease_time!(lease_time),
    do: raise(ArgumentError, "Invalid dnsmasq :lease_time #{inspect(lease_time)}")

  defp check_path(dnsmasq, key, directive) do
    case dnsmasq do
      %{^key => path} when is_binary(path) ->
        if Path.type(path) == :absolute and String.trim(path) == path and
             not Regex.match?(~r/[\x00-\x1f\x7f"]| #/, path) do
          check_line!("#{directive}=#{path}", "dnsmasq #{inspect(key)}")
          dnsmasq
        else
          raise ArgumentError, "Invalid dnsmasq #{inspect(key)} #{inspect(path)}"
        end

      %{^key => path} ->
        raise ArgumentError, "Invalid dnsmasq #{inspect(key)} #{inspect(path)}"

      _ ->
        dnsmasq
    end
  end

  defp check_authoritative(%{authoritative: value}) when not is_boolean(value),
    do: raise(ArgumentError, "Expected a boolean for :authoritative, got: #{inspect(value)}")

  defp check_authoritative(dnsmasq), do: dnsmasq

  defp normalize_leases(leases, ipv4) when is_list(leases) do
    leases = Enum.map(leases, &normalize_lease(&1, ipv4))

    if length(Enum.uniq_by(leases, &lease_mac/1)) != length(leases) do
      raise ArgumentError, "Duplicate MAC address in dnsmasq :static_leases"
    end

    ips = leases |> Enum.map(&lease_ip/1) |> Enum.reject(&is_nil/1)

    if length(Enum.uniq(ips)) != length(ips) do
      raise ArgumentError, "Duplicate IP address in dnsmasq :static_leases"
    end

    leases
  end

  defp normalize_leases(leases, _ipv4),
    do: raise(ArgumentError, "Expected a list for :static_leases, got: #{inspect(leases)}")

  defp normalize_lease({mac, ip}, ipv4), do: {check_mac(mac), lease_ip!(ip, ipv4)}

  defp normalize_lease({mac, ip, hostname}, ipv4),
    do: {check_mac(mac), lease_ip!(ip, ipv4), check_hostname(hostname)}

  defp normalize_lease(%{mac: mac, ignore: true} = lease, _ipv4) when map_size(lease) == 2,
    do: %{mac: check_mac(mac), ignore: true}

  defp normalize_lease(%{mac: mac} = lease, ipv4) do
    host =
      lease
      |> Map.take([:ip, :hostname, :lease_time])
      |> Map.new(fn
        {:ip, ip} -> {:ip, lease_ip!(ip, ipv4)}
        {:hostname, hostname} -> {:hostname, check_hostname(hostname)}
        {:lease_time, lease_time} -> {:lease_time, lease_time!(lease_time)}
      end)

    if host == %{} or map_size(host) + 1 != map_size(lease) do
      raise ArgumentError, "Invalid dnsmasq static lease #{inspect(lease)}"
    end

    Map.put(host, :mac, check_mac(mac))
  end

  defp normalize_lease(lease, _ipv4),
    do: raise(ArgumentError, "Invalid dnsmasq static lease #{inspect(lease)}")

  @doc false
  @spec lease_mac(tuple() | map()) :: String.t()
  def lease_mac(%{mac: mac}), do: mac
  def lease_mac(lease), do: elem(lease, 0)

  @doc false
  @spec lease_ip(tuple() | map()) :: :inet.ip4_address() | nil
  def lease_ip(%{} = lease), do: lease[:ip]
  def lease_ip(lease), do: elem(lease, 1)

  defp lease_ip!(ip, ipv4) do
    {a, b, c, d} = ip = subnet_ip!(ip, ipv4)
    prefix_length = ipv4.prefix_length
    host_count = Integer.pow(2, 32 - prefix_length)
    <<address::32>> = <<a, b, c, d>>
    host = rem(address, host_count)

    if ip == ipv4.address do
      raise ArgumentError, "A dnsmasq static lease can't use the interface's address"
    end

    if prefix_length <= 30 and host in [0, host_count - 1] do
      raise ArgumentError, "A dnsmasq static lease can't use the network or broadcast address"
    end

    ip
  end

  defp check_mac(mac) when is_binary(mac) do
    if mac =~ ~r/\A[[:xdigit:]]{2}(:[[:xdigit:]]{2}){5}\z/ do
      String.downcase(mac)
    else
      raise ArgumentError, "Invalid MAC address #{inspect(mac)}"
    end
  end

  defp check_mac(mac), do: raise(ArgumentError, "Invalid MAC address #{inspect(mac)}")

  # dnsmasq reads these as a keyword or a lease time rather than a hostname
  defp check_hostname(hostname) when hostname in ["ignore", "infinite"],
    do: raise(ArgumentError, "Invalid hostname #{inspect(hostname)}")

  defp check_hostname(hostname) when is_binary(hostname) and byte_size(hostname) <= 63 do
    if hostname =~ ~r/\A[[:alnum:]]([[:alnum:]-]*[[:alnum:]])?\z/ and
         not (hostname =~ ~r/\A\d+[smhdwSMHDW]?\z/) do
      hostname
    else
      raise ArgumentError, "Invalid hostname #{inspect(hostname)}"
    end
  end

  defp check_hostname(hostname), do: raise(ArgumentError, "Invalid hostname #{inspect(hostname)}")

  defp update_list(dnsmasq, key, fun) do
    Map.update(dnsmasq, key, [], fn
      list when is_list(list) -> Enum.map(list, fun)
      other -> raise ArgumentError, "Expected a list for #{inspect(key)}, got: #{inspect(other)}"
    end)
  end

  defp normalize_record({name, ip}), do: {dns_name!(name), ip!(ip)}

  defp normalize_record(record),
    do: raise(ArgumentError, "Invalid dnsmasq record #{inspect(record)}")

  defp normalize_domain_record({"#", ip}), do: {"#", ip!(ip)}
  defp normalize_domain_record({pattern, ip}), do: {domain_pattern!(pattern), ip!(ip)}

  defp normalize_domain_record(record),
    do: raise(ArgumentError, "Invalid dnsmasq domain record #{inspect(record)}")

  defp normalize_cname({name, target}), do: {dns_name!(name), dns_name!(target)}
  defp normalize_cname(cname), do: raise(ArgumentError, "Invalid dnsmasq CNAME #{inspect(cname)}")

  defp check_cnames(%{cnames: cnames} = dnsmasq) do
    targets =
      Map.new(cnames, fn {name, target} -> {String.downcase(name), String.downcase(target)} end)

    if map_size(targets) != length(cnames) do
      raise ArgumentError, "dnsmasq CNAME aliases must be unique"
    end

    Enum.each(Map.keys(targets), &check_cname_chain(&1, targets, %{}))
    dnsmasq
  end

  defp check_cname_chain(name, targets, visited) do
    case targets do
      %{^name => target} ->
        if Map.has_key?(visited, name) do
          raise ArgumentError, "dnsmasq CNAME loop involving #{inspect(name)}"
        end

        check_cname_chain(target, targets, Map.put(visited, name, target))

      _ ->
        :ok
    end
  end

  defp normalize_srv({name, target, port}) when port in 0..65_535,
    do: {dns_name!(name), srv_target!(target), port}

  defp normalize_srv({name, target, port, priority, weight})
       when port in 0..65_535 and priority in 0..65_535 and weight in 0..65_535,
       do: {dns_name!(name), srv_target!(target), port, priority, weight}

  defp normalize_srv(srv), do: raise(ArgumentError, "Invalid dnsmasq SRV record #{inspect(srv)}")

  defp srv_target!("."), do: "."
  defp srv_target!(target), do: dns_name!(target)

  defp normalize_txt({name, texts}) when is_list(texts) do
    record = {dns_name!(name), Enum.map(texts, &text!/1)}
    check_line!(txt_record_line(record), "dnsmasq TXT record #{inspect(name)}")
    record
  end

  defp normalize_txt({name, text}), do: normalize_txt({name, [text]})
  defp normalize_txt(txt), do: raise(ArgumentError, "Invalid dnsmasq TXT record #{inspect(txt)}")

  defp text!(text) when is_binary(text) and byte_size(text) <= 255 do
    if text =~ ~r/\A[^\x00-\x1f\x7f]*\z/ do
      text
    else
      raise ArgumentError, "Invalid dnsmasq TXT string #{inspect(text)}"
    end
  end

  defp text!(text), do: raise(ArgumentError, "Invalid dnsmasq TXT string #{inspect(text)}")

  defp normalize_mx({name, target}), do: {dns_name!(name), dns_name!(target)}

  defp normalize_mx({name, target, preference}) when preference in 0..65_535,
    do: {dns_name!(name), dns_name!(target), preference}

  defp normalize_mx(mx), do: raise(ArgumentError, "Invalid dnsmasq MX record #{inspect(mx)}")

  defp normalize_nftset({domains, sets})
       when domains not in [nil, []] and sets not in [nil, []] do
    nftset =
      {Enum.map(List.wrap(domains), &nftset_domain!/1), Enum.map(List.wrap(sets), &nftset!/1)}

    check_line!(nftset_line(nftset), "dnsmasq nftset #{inspect(nftset)}")
    nftset
  end

  defp normalize_nftset(nftset),
    do: raise(ArgumentError, "Invalid dnsmasq nftset #{inspect(nftset)}")

  defp nftset_domain!("#"), do: "#"

  defp nftset_domain!(domain) when is_binary(domain) do
    name = domain |> String.trim_leading(".") |> String.replace_suffix(".", "")

    if name == "" or dns_name?(name) do
      domain
    else
      raise ArgumentError, "Invalid dnsmasq nftset domain #{inspect(domain)}"
    end
  end

  defp nftset_domain!(domain),
    do: raise(ArgumentError, "Invalid dnsmasq nftset domain #{inspect(domain)}")

  defp nftset!(set) when is_binary(set) do
    if set =~ ~r/\A([46]#)?([[:alnum:]_.-]+#)?[[:alnum:]_.-]+#[[:alnum:]_.-]+\z/ do
      set
    else
      raise ArgumentError, "Invalid nftables set #{inspect(set)}"
    end
  end

  defp nftset!(set), do: raise(ArgumentError, "Invalid nftables set #{inspect(set)}")

  @ip_list_options [:dns, :router, :ntp]
  @list_options [:search | @ip_list_options]

  defp normalize_options(options, ipv4) when is_map(options) do
    options = Map.new(options, &normalize_option(&1, ipv4))

    Enum.each(options, fn {key, _value} = option ->
      check_line!(String.trim_trailing(option_line(option)), "dnsmasq option #{inspect(key)}")
    end)

    options
  end

  defp normalize_options(options, _ipv4),
    do: raise(ArgumentError, "Expected a map for dnsmasq :options, got: #{inspect(options)}")

  defp normalize_option({:netmask, mask}, ipv4), do: normalize_option({:subnet, mask}, ipv4)

  defp normalize_option({:subnet, mask}, ipv4) do
    if ipv4!(mask) == IP.prefix_length_to_subnet_mask(:inet, ipv4.prefix_length) do
      {:subnet, ipv4!(mask)}
    else
      raise ArgumentError, "dnsmasq :subnet must match the interface's prefix length"
    end
  end

  defp normalize_option({:serverid, ip}, ipv4) do
    if ipv4!(ip) == ipv4.address do
      {:serverid, ipv4.address}
    else
      raise ArgumentError, "dnsmasq :serverid must be the interface's address"
    end
  end

  defp normalize_option({option, ips}, _ipv4) when option in @ip_list_options and is_list(ips),
    do: {option, Enum.map(ips, &ipv4!/1)}

  defp normalize_option({:search, names}, _ipv4) when is_list(names),
    do: {:search, Enum.map(names, &dns_name!/1)}

  defp normalize_option({option, one_item}, ipv4) when option in @list_options,
    do: normalize_option({option, [one_item]}, ipv4)

  defp normalize_option({option, name}, _ipv4) when option in [:domain, :hostname],
    do: {option, dns_name!(name)}

  defp normalize_option({:mtu, mtu}, _ipv4) when mtu in 68..65_535, do: {:mtu, mtu}

  defp normalize_option({number, value}, _ipv4) when number in 1..254 and is_binary(value) do
    if String.contains?(value, ["\n", "\r", "\0"]) do
      raise ArgumentError, "Invalid dnsmasq option #{number} value #{inspect(value)}"
    end

    {number, value}
  end

  defp normalize_option(option, _ipv4),
    do: raise(ArgumentError, "Invalid dnsmasq option #{inspect(option)}")

  defp normalize_name_servers(%{name_servers: servers} = dnsmasq),
    do: %{dnsmasq | name_servers: ip_list!(servers)}

  defp normalize_name_servers(dnsmasq), do: dnsmasq

  defp normalize_domain(%{domain: domain} = dnsmasq), do: %{dnsmasq | domain: dns_name!(domain)}
  defp normalize_domain(dnsmasq), do: dnsmasq

  defp normalize_forward_domain({domain, servers}),
    do: {domain_pattern!(domain), ip_list!(servers)}

  defp normalize_forward_domain(forward),
    do: raise(ArgumentError, "Invalid dnsmasq forward domain #{inspect(forward)}")

  defp ip_list!(ips) when is_list(ips), do: Enum.map(ips, &ip!/1)
  defp ip_list!(ip), do: [ip!(ip)]

  defp ip!(ip) do
    with {:ok, address} <- IP.ip_to_tuple(ip),
         true <- Enum.all?(Tuple.to_list(address), &is_integer/1) do
      address
    else
      _ -> raise ArgumentError, "Invalid IP address #{inspect(ip)}"
    end
  end

  defp domain_pattern!(pattern) when is_binary(pattern) do
    domain =
      pattern
      |> String.replace_prefix("*", "")
      |> String.replace_prefix(".", "")
      |> String.replace_suffix(".", "")

    if domain == "" or dns_name?(domain) do
      pattern
    else
      raise ArgumentError, "Invalid dnsmasq domain pattern #{inspect(pattern)}"
    end
  end

  defp domain_pattern!(pattern),
    do: raise(ArgumentError, "Invalid dnsmasq domain pattern #{inspect(pattern)}")

  defp dns_name!(name) do
    if dns_name?(name), do: name, else: raise(ArgumentError, "Invalid DNS name #{inspect(name)}")
  end

  defp dns_name?(name) when is_binary(name) and byte_size(name) <= 253 do
    label = ~r/\A[[:alnum:]_]([[:alnum:]_-]{0,61}[[:alnum:]_])?\z/
    name |> String.split(".") |> Enum.all?(&(&1 =~ label))
  end

  defp dns_name?(_name), do: false

  defp ipv4!(ip) do
    case IP.ip_to_tuple(ip) do
      {:ok, {a, b, c, d} = ip}
      when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) ->
        ip

      _ ->
        raise ArgumentError, "Invalid IPv4 address #{inspect(ip)}"
    end
  end

  defp subnet_ip!(ip, %{address: address, prefix_length: prefix_length}) do
    ip = ipv4!(ip)

    if IP.to_subnet(ip, prefix_length) == IP.to_subnet(address, prefix_length) do
      ip
    else
      raise ArgumentError, "#{IP.ip_to_string(ip)} isn't on the interface's subnet"
    end
  end

  @doc """
  Add the dnsmasq configuration file and daemon
  """
  @spec add_config(RawConfig.t(), map(), keyword()) :: RawConfig.t()
  def add_config(
        %RawConfig{ifname: ifname} = raw_config,
        %{ipv4: %{method: :static} = ipv4, dnsmasq: dnsmasq},
        opts
      ) do
    tmpdir = Keyword.fetch!(opts, :tmpdir)
    notify_name = "dnsmasqex_#{ifname}"

    context = %{
      ifname: ifname,
      address: ipv4.address,
      prefix_length: ipv4.prefix_length,
      lease_path: lease_path(dnsmasq, tmpdir, ifname)
    }

    notifier_options = [
      name: notify_name,
      report_env: true,
      dispatcher: &Notifications.dispatch(&1, &2, context)
    ]

    notifier = Supervisor.child_spec({BEAMNotify, notifier_options}, id: :dnsmasq_notify)

    server =
      {Server, ifname: ifname, tmpdir: tmpdir, config: %{ipv4: ipv4, dnsmasq: dnsmasq}}

    daemon =
      Supervisor.child_spec(
        {Daemon,
         ifname: ifname,
         command: dnsmasq_path(),
         args: ["-k", "-C", conf_path(tmpdir, ifname), "--log-facility=-"],
         opts:
           Command.add_muon_options(
             env: BEAMNotify.env(notifier_options),
             stderr_to_stdout: true,
             log_output: :debug
           )},
        id: :dnsmasq
      )

    %{
      raw_config
      | files:
          [
            {conf_path(tmpdir, ifname), dnsmasq_contents(dnsmasq, ifname, ipv4, tmpdir)}
            | Enum.map(@runtime_options, &runtime_file(&1, dnsmasq, tmpdir, ifname))
          ] ++ raw_config.files,
        cleanup_files:
          [
            pid_path(tmpdir, ifname)
            | Enum.map(@runtime_options, &(runtime_path(&1, tmpdir, ifname) <> ".new"))
          ] ++ raw_config.cleanup_files,
        up_cmds: raw_config.up_cmds ++ lease_dir_cmds(dnsmasq),
        child_specs: raw_config.child_specs ++ [server, notifier, daemon],
        down_cmds: raw_config.down_cmds ++ [{:fun, Notifications, :clear, [ifname]}]
    }
  end

  def add_config(raw_config, _config_without_dnsmasq, _opts), do: raw_config

  defp lease_dir_cmds(%{lease_path: path}), do: [{:fun, File, :mkdir_p, [Path.dirname(path)]}]
  defp lease_dir_cmds(_dnsmasq), do: []

  defp dnsmasq_contents(dnsmasq, ifname, ipv4, tmpdir) do
    [
      "interface=#{ifname}",
      "except-interface=lo",
      "listen-address=#{IP.ip_to_string(ipv4.address)}",
      "bind-interfaces",
      "no-hosts",
      upstream(dnsmasq),
      local_domain(dnsmasq),
      "user=root",
      "pid-file=#{pid_path(tmpdir, ifname)}",
      "dhcp-leasefile=#{lease_path(dnsmasq, tmpdir, ifname)}",
      "dhcp-script=#{BEAMNotify.bin_path()}",
      "script-arp",
      "script-on-renewal",
      authoritative(dnsmasq),
      dhcp_range(dnsmasq, ipv4),
      "dhcp-hostsfile=#{runtime_path(:static_leases, tmpdir, ifname)}",
      "dhcp-optsfile=#{runtime_path(:options, tmpdir, ifname)}",
      hosts_dir(dnsmasq),
      "addn-hosts=#{runtime_path(:records, tmpdir, ifname)}",
      Enum.map(dnsmasq.domain_records, fn {name, ip} ->
        "address=/#{name}/#{IP.ip_to_string(ip)}"
      end),
      Enum.map(dnsmasq.cnames, fn {name, target} -> "cname=#{name},#{target}" end),
      Enum.map(dnsmasq.srv_records, &("srv-host=" <> Enum.join(Tuple.to_list(&1), ","))),
      Enum.map(dnsmasq.txt_records, &txt_record_line/1),
      Enum.map(dnsmasq.mx_records, &("mx-host=" <> Enum.join(Tuple.to_list(&1), ","))),
      Enum.map(dnsmasq.nftsets, &nftset_line/1)
    ]
    |> List.flatten()
    |> Enum.map_join(&[&1, "\n"])
  end

  defp upstream(dnsmasq) do
    resolv = if Map.has_key?(dnsmasq, :name_servers), do: ["no-resolv"], else: []
    servers = Enum.map(Map.get(dnsmasq, :name_servers, []), &"server=#{IP.ip_to_string(&1)}")

    forwards =
      for {domain, servers} <- dnsmasq.forward_domains,
          server <- if(servers == [], do: [""], else: Enum.map(servers, &IP.ip_to_string/1)),
          do: "server=/#{domain}/#{server}"

    resolv ++ servers ++ forwards
  end

  defp authoritative(%{authoritative: true}), do: "dhcp-authoritative"
  defp authoritative(_dnsmasq), do: []

  defp local_domain(%{domain: domain}),
    do: ["domain=#{domain}", "local=/#{domain}/", "expand-hosts"]

  defp local_domain(_dnsmasq), do: []

  defp dhcp_range(%{start: first, end: last} = dnsmasq, _ipv4) do
    range_line([IP.ip_to_string(first), IP.ip_to_string(last)], dnsmasq)
  end

  defp dhcp_range(dnsmasq, ipv4) do
    if dhcp_enabled?(dnsmasq), do: static_range(dnsmasq, ipv4), else: []
  end

  @doc false
  @spec dhcp_enabled?(map()) :: boolean()
  def dhcp_enabled?(%{start: _, end: _}), do: true
  def dhcp_enabled?(%{hosts_dir: _}), do: true
  def dhcp_enabled?(%{static_leases: [_ | _]}), do: true
  def dhcp_enabled?(_dnsmasq), do: false

  defp static_range(dnsmasq, ipv4) do
    subnet = IP.to_subnet(ipv4.address, ipv4.prefix_length)
    range_line([IP.ip_to_string(subnet), "static"], dnsmasq)
  end

  defp range_line(fields, dnsmasq) do
    "dhcp-range=" <> Enum.join(fields ++ lease_time(dnsmasq[:lease_time]), ",")
  end

  defp lease_time(nil), do: []
  defp lease_time(:infinite), do: ["infinite"]
  defp lease_time(seconds), do: [Integer.to_string(seconds)]

  defp hosts_dir(%{hosts_dir: hosts_dir}), do: "dhcp-hostsdir=#{hosts_dir}"
  defp hosts_dir(_dnsmasq), do: []

  @doc false
  @spec runtime_options() :: [runtime_option(), ...]
  def runtime_options(), do: @runtime_options

  @doc false
  @spec runtime_file(runtime_option(), map(), Path.t(), VintageNet.ifname()) ::
          {Path.t(), String.t()}
  def runtime_file(key, dnsmasq, tmpdir, ifname),
    do: {runtime_path(key, tmpdir, ifname), runtime_contents(key, Map.fetch!(dnsmasq, key))}

  defp runtime_contents(:static_leases, leases), do: Enum.map_join(leases, &host_line/1)

  defp runtime_contents(:records, records),
    do: Enum.map_join(records, fn {name, ip} -> "#{IP.ip_to_string(ip)} #{name}\n" end)

  defp runtime_contents(:options, options),
    do: options |> Enum.sort() |> Enum.map_join(&option_line/1)

  defp host_line({mac, ip}), do: "#{mac},#{IP.ip_to_string(ip)},infinite\n"
  defp host_line({mac, ip, hostname}), do: "#{mac},#{IP.ip_to_string(ip)},#{hostname},infinite\n"
  defp host_line(%{mac: mac, ignore: true}), do: "#{mac},ignore\n"

  defp host_line(%{mac: mac} = lease) do
    lease_time = Map.get(lease, :lease_time, if(lease[:ip], do: :infinite))

    fields =
      Enum.reject([mac, lease[:ip] && IP.ip_to_string(lease.ip), lease[:hostname]], &is_nil/1)

    Enum.join(fields ++ lease_time(lease_time), ",") <> "\n"
  end

  defp option_line({option, _value}) when option in [:serverid, :subnet], do: ""
  defp option_line({number, ""}) when is_integer(number), do: "#{number}\n"
  defp option_line({number, value}) when is_integer(number), do: "#{number},#{value}\n"
  defp option_line({:mtu, mtu}), do: "option:mtu,#{mtu}\n"

  defp option_line({option, values}) when is_list(values),
    do: Enum.map_join([dnsmasq_option(option) | values], ",", &value_string/1) <> "\n"

  defp option_line({option, name}), do: "#{dnsmasq_option(option)},#{name}\n"

  defp dnsmasq_option(:dns), do: "option:dns-server"
  defp dnsmasq_option(:router), do: "option:router"
  defp dnsmasq_option(:ntp), do: "option:ntp-server"
  defp dnsmasq_option(:search), do: "option:domain-search"
  defp dnsmasq_option(:domain), do: "option:domain-name"
  defp dnsmasq_option(:hostname), do: "12"

  defp nftset_line({domains, sets}),
    do: "nftset=/#{Enum.join(domains, "/")}/#{Enum.join(sets, ",")}"

  # dnsmasq reads its files 1024 bytes at a time and parses the rest of a longer
  # line as a line of its own
  defp check_line!(line, what) do
    if byte_size(line) > 1024 do
      raise ArgumentError, "#{what} exceeds dnsmasq's 1024-byte line limit"
    end

    :ok
  end

  defp txt_record_line({name, texts}),
    do: Enum.join(["txt-record=#{name}" | Enum.map(texts, &quote_text/1)], ",")

  defp quote_text(text),
    do: ~s("#{text |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")}")

  defp value_string(value) when is_tuple(value), do: IP.ip_to_string(value)
  defp value_string(value), do: value

  @doc false
  @spec conf_path(Path.t(), VintageNet.ifname()) :: Path.t()
  def conf_path(tmpdir, ifname), do: Path.join(tmpdir, "dnsmasq.conf.#{ifname}")

  @doc false
  @spec pid_path(Path.t(), VintageNet.ifname()) :: Path.t()
  def pid_path(tmpdir, ifname), do: Path.join(tmpdir, "dnsmasq.#{ifname}.pid")

  @doc false
  @spec runtime_path(runtime_option(), Path.t(), VintageNet.ifname()) :: Path.t()
  def runtime_path(:static_leases, tmpdir, ifname),
    do: Path.join(tmpdir, "dnsmasq.#{ifname}.hosts")

  def runtime_path(:options, tmpdir, ifname), do: Path.join(tmpdir, "dnsmasq.#{ifname}.options")
  def runtime_path(:records, tmpdir, ifname), do: Path.join(tmpdir, "dnsmasq.#{ifname}.records")

  defp lease_path(%{lease_path: path}, _tmpdir, _ifname), do: path
  defp lease_path(_dnsmasq, tmpdir, ifname), do: Path.join(tmpdir, "dnsmasq.#{ifname}.leases")

  @doc false
  @spec dnsmasq_path() :: String.t()
  def dnsmasq_path(), do: Application.get_env(:dnsmasqex, :dnsmasq, "dnsmasq")
end
