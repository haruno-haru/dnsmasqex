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
    infinite leases
  * `:records` - `{name, ip}` pairs, including their subdomains
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
  * `:hosts_dir` - an absolute path to a directory of `dhcp-host` files. New
    files are read automatically
  """

  alias VintageNet.Command
  alias VintageNet.Interface.RawConfig
  alias VintageNet.IP
  alias Dnsmasqex.Daemon
  alias Dnsmasqex.Notifications

  @runtime_options [:static_leases, :options]

  @typedoc false
  @type runtime_option :: :static_leases | :options

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
        :options,
        :name_servers,
        :forward_domains,
        :domain,
        :hosts_dir
      ])
      |> normalize_range(ipv4)
      |> check_lease_time()
      |> check_hosts_dir()
      |> Map.update(:static_leases, [], &normalize_leases(&1, ipv4))
      |> Map.update(:records, [], &normalize_records/1)
      |> Map.update(:options, %{}, &normalize_options(&1, ipv4))
      |> normalize_name_servers()
      |> Map.update(:forward_domains, [], &normalize_forward_domains/1)
      |> normalize_domain()

    %{config | dnsmasq: new_dnsmasq}
  end

  def normalize(%{ipv4: %{method: :static}, dnsmasq: dnsmasq}),
    do: raise(ArgumentError, "Expected a map for :dnsmasq, got: #{inspect(dnsmasq)}")

  def normalize(%{dnsmasq: _not_static} = config), do: Map.drop(config, [:dnsmasq])
  def normalize(config), do: config

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

  defp check_lease_time(%{lease_time: lease_time} = dnsmasq)
       when lease_time == :infinite or
              (is_integer(lease_time) and lease_time in 120..0xFFFFFFFE),
       do: dnsmasq

  defp check_lease_time(%{lease_time: lease_time}),
    do: raise(ArgumentError, "Invalid dnsmasq :lease_time #{inspect(lease_time)}")

  defp check_lease_time(dnsmasq), do: dnsmasq

  defp check_hosts_dir(%{hosts_dir: hosts_dir} = dnsmasq) when is_binary(hosts_dir) do
    if Path.type(hosts_dir) == :absolute and String.trim(hosts_dir) == hosts_dir and
         not Regex.match?(~r/[\x00-\x1f\x7f"]| #/, hosts_dir) do
      dnsmasq
    else
      raise ArgumentError, "Invalid dnsmasq :hosts_dir #{inspect(hosts_dir)}"
    end
  end

  defp check_hosts_dir(%{hosts_dir: hosts_dir}),
    do: raise(ArgumentError, "Invalid dnsmasq :hosts_dir #{inspect(hosts_dir)}")

  defp check_hosts_dir(dnsmasq), do: dnsmasq

  defp normalize_leases(leases, ipv4) when is_list(leases) do
    leases = Enum.map(leases, &normalize_lease(&1, ipv4))

    if length(Enum.uniq_by(leases, &elem(&1, 0))) != length(leases) do
      raise ArgumentError, "Duplicate MAC address in dnsmasq :static_leases"
    end

    if length(Enum.uniq_by(leases, &elem(&1, 1))) != length(leases) do
      raise ArgumentError, "Duplicate IP address in dnsmasq :static_leases"
    end

    leases
  end

  defp normalize_leases(leases, _ipv4),
    do: raise(ArgumentError, "Expected a list for :static_leases, got: #{inspect(leases)}")

  defp normalize_lease({mac, ip}, ipv4), do: {check_mac(mac), lease_ip!(ip, ipv4)}

  defp normalize_lease({mac, ip, hostname}, ipv4),
    do: {check_mac(mac), lease_ip!(ip, ipv4), check_hostname(hostname)}

  defp normalize_lease(lease, _ipv4),
    do: raise(ArgumentError, "Invalid dnsmasq static lease #{inspect(lease)}")

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

  defp normalize_records(records) when is_list(records),
    do: Enum.map(records, &normalize_record/1)

  defp normalize_records(records),
    do: raise(ArgumentError, "Expected a list for :records, got: #{inspect(records)}")

  defp normalize_record({name, ip}) when is_binary(name) do
    domain =
      name
      |> String.replace_prefix("*", "")
      |> String.trim_leading(".")
      |> String.trim_trailing(".")

    if name =~ ~r/\A[^\s\x00-\x1f\x7f\/#"]+\z/ and byte_size(domain) <= 253 and
         (domain == "" or Enum.all?(String.split(domain, "."), &(byte_size(&1) in 1..63))) do
      {name, ipv4!(ip)}
    else
      raise ArgumentError, "Invalid dnsmasq record name #{inspect(name)}"
    end
  end

  defp normalize_record(record),
    do: raise(ArgumentError, "Invalid dnsmasq record #{inspect(record)}")

  @ip_list_options [:dns, :router, :ntp]
  @list_options [:search | @ip_list_options]

  defp normalize_options(options, ipv4) when is_map(options),
    do: Map.new(options, &normalize_option(&1, ipv4))

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

  defp normalize_forward_domains(domains) when is_list(domains),
    do: Enum.map(domains, &normalize_forward_domain/1)

  defp normalize_forward_domains(domains),
    do: raise(ArgumentError, "Expected a list for :forward_domains, got: #{inspect(domains)}")

  defp normalize_forward_domain({domain, servers}), do: {dns_name!(domain), ip_list!(servers)}

  defp normalize_forward_domain(forward),
    do: raise(ArgumentError, "Invalid dnsmasq forward domain #{inspect(forward)}")

  defp ip_list!(ips) when is_list(ips), do: Enum.map(ips, &ip!/1)
  defp ip_list!(ip), do: [ip!(ip)]

  defp ip!(ip) do
    case IP.ip_to_tuple(ip) do
      {:ok, ip} -> ip
      {:error, _} -> raise ArgumentError, "Invalid IP address #{inspect(ip)}"
    end
  end

  defp dns_name!(name) when is_binary(name) and byte_size(name) <= 253 do
    label = ~r/\A[[:alnum:]_]([[:alnum:]_-]{0,61}[[:alnum:]_])?\z/

    if name |> String.split(".") |> Enum.all?(&(&1 =~ label)) do
      name
    else
      raise ArgumentError, "Invalid DNS name #{inspect(name)}"
    end
  end

  defp dns_name!(name), do: raise(ArgumentError, "Invalid DNS name #{inspect(name)}")

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
      lease_path: lease_path(tmpdir, ifname)
    }

    notifier_options = [
      name: notify_name,
      report_env: true,
      dispatcher: &Notifications.dispatch(&1, &2, context)
    ]

    notifier = Supervisor.child_spec({BEAMNotify, notifier_options}, id: :dnsmasq_notify)

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
        child_specs: raw_config.child_specs ++ [notifier, daemon],
        down_cmds: raw_config.down_cmds ++ [{:fun, Notifications, :clear, [ifname]}]
    }
  end

  def add_config(raw_config, _config_without_dnsmasq, _opts), do: raw_config

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
      "dhcp-leasefile=#{lease_path(tmpdir, ifname)}",
      "dhcp-script=#{BEAMNotify.bin_path()}",
      "script-arp",
      "script-on-renewal",
      dhcp_range(dnsmasq, ipv4),
      "dhcp-hostsfile=#{runtime_path(:static_leases, tmpdir, ifname)}",
      "dhcp-optsfile=#{runtime_path(:options, tmpdir, ifname)}",
      hosts_dir(dnsmasq),
      Enum.map(dnsmasq.records, fn {name, ip} -> "address=/#{name}/#{IP.ip_to_string(ip)}" end)
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

  defp runtime_contents(:options, options),
    do: options |> Enum.sort() |> Enum.map_join(&option_line/1)

  defp host_line({mac, ip}), do: "#{mac},#{IP.ip_to_string(ip)},infinite\n"
  defp host_line({mac, ip, hostname}), do: "#{mac},#{IP.ip_to_string(ip)},#{hostname},infinite\n"

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

  defp lease_path(tmpdir, ifname), do: Path.join(tmpdir, "dnsmasq.#{ifname}.leases")

  @doc false
  @spec dnsmasq_path() :: String.t()
  def dnsmasq_path(), do: Application.get_env(:dnsmasqex, :dnsmasq, "dnsmasq")
end
