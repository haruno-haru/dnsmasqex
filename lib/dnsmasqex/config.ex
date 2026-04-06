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
  * `:hosts_dir` - an absolute path to a directory of `dhcp-host` files. New
    files are read automatically

  Other names are forwarded to the name servers in `/etc/resolv.conf`.
  """

  alias VintageNet.Command
  alias VintageNet.Interface.RawConfig
  alias VintageNet.IP
  alias Dnsmasqex.Daemon
  alias Dnsmasqex.Notifications

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
      |> Map.take([:start, :end, :lease_time, :static_leases, :records, :hosts_dir])
      |> normalize_range(ipv4)
      |> check_lease_time()
      |> check_hosts_dir()
      |> Map.update(:static_leases, [], &normalize_leases(&1, ipv4))
      |> Map.update(:records, [], &normalize_records/1)

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

  defp check_ipv4(%{address: {_, _, _, _} = address, prefix_length: prefix_length})
       when is_integer(prefix_length) and prefix_length in 0..32 do
    _ = ipv4!(address)
    :ok
  end

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
      | files: [
          {conf_path(tmpdir, ifname), dnsmasq_contents(dnsmasq, ifname, ipv4, tmpdir)},
          {hosts_path(tmpdir, ifname), hosts_contents(dnsmasq.static_leases)} | raw_config.files
        ],
        cleanup_files: [pid_path(tmpdir, ifname) | raw_config.cleanup_files],
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
      "user=root",
      "pid-file=#{pid_path(tmpdir, ifname)}",
      "dhcp-leasefile=#{lease_path(tmpdir, ifname)}",
      "dhcp-script=#{BEAMNotify.bin_path()}",
      "script-arp",
      "script-on-renewal",
      dhcp_range(dnsmasq, ipv4),
      "dhcp-hostsfile=#{hosts_path(tmpdir, ifname)}",
      hosts_dir(dnsmasq),
      Enum.map(dnsmasq.records, fn {name, ip} -> "address=/#{name}/#{IP.ip_to_string(ip)}" end)
    ]
    |> List.flatten()
    |> Enum.map_join(&[&1, "\n"])
  end

  defp dhcp_range(%{start: first, end: last} = dnsmasq, _ipv4) do
    range_line([IP.ip_to_string(first), IP.ip_to_string(last)], dnsmasq)
  end

  defp dhcp_range(%{static_leases: [], hosts_dir: _} = dnsmasq, ipv4),
    do: static_range(dnsmasq, ipv4)

  defp dhcp_range(%{static_leases: [_ | _]} = dnsmasq, ipv4), do: static_range(dnsmasq, ipv4)
  defp dhcp_range(_dns_only, _ipv4), do: []

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
  @spec hosts_contents([tuple()]) :: String.t()
  def hosts_contents(static_leases), do: Enum.map_join(static_leases, &host_line/1)

  defp host_line({mac, ip}), do: "#{mac},#{IP.ip_to_string(ip)},infinite\n"
  defp host_line({mac, ip, hostname}), do: "#{mac},#{IP.ip_to_string(ip)},#{hostname},infinite\n"

  @doc false
  @spec conf_path(Path.t(), VintageNet.ifname()) :: Path.t()
  def conf_path(tmpdir, ifname), do: Path.join(tmpdir, "dnsmasq.conf.#{ifname}")

  @doc false
  @spec pid_path(Path.t(), VintageNet.ifname()) :: Path.t()
  def pid_path(tmpdir, ifname), do: Path.join(tmpdir, "dnsmasq.#{ifname}.pid")

  @doc false
  @spec hosts_path(Path.t(), VintageNet.ifname()) :: Path.t()
  def hosts_path(tmpdir, ifname), do: Path.join(tmpdir, "dnsmasq.#{ifname}.hosts")

  defp lease_path(tmpdir, ifname), do: Path.join(tmpdir, "dnsmasq.#{ifname}.leases")

  @doc false
  @spec dnsmasq_path() :: String.t()
  def dnsmasq_path(), do: Application.get_env(:dnsmasqex, :dnsmasq, "dnsmasq")
end
