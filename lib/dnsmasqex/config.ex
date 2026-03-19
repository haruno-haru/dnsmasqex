# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.Config do
  @moduledoc """
  dnsmasq options for a static IPv4 interface

  * `:start` and `:end` - DHCP address range. Omit them for DNS only
  * `:lease_time` - seconds or `:infinite`
  * `:static_leases` - `{mac, ip}` or `{mac, ip, hostname}` tuples with
    infinite leases
  * `:records` - `{name, ip}` pairs, including their subdomains
  * `:hosts_dir` - a directory of `dhcp-host` files. New files are read
    automatically

  Other names are forwarded to the name servers in `/etc/resolv.conf`.
  """

  alias VintageNet.Interface.RawConfig
  alias VintageNet.IP
  alias Dnsmasqex.Daemon
  alias Dnsmasqex.Notifications

  @doc """
  Normalize the `:dnsmasq` options
  """
  @spec normalize(map()) :: map()
  def normalize(%{ipv4: %{method: :static}, dnsmasq: dnsmasq} = config) do
    new_dnsmasq =
      dnsmasq
      |> Map.take([:start, :end, :lease_time, :static_leases, :records, :hosts_dir])
      |> check_range()
      |> check_lease_time()
      |> check_hosts_dir()
      |> Map.replace_lazy(:start, &IP.ip_to_tuple!/1)
      |> Map.replace_lazy(:end, &IP.ip_to_tuple!/1)
      |> Map.update(:static_leases, [], &normalize_static_leases/1)
      |> Map.update(:records, [], fn records -> Enum.map(records, &normalize_record/1) end)

    %{config | dnsmasq: new_dnsmasq}
  end

  def normalize(%{dnsmasq: _not_static} = config), do: Map.drop(config, [:dnsmasq])
  def normalize(config), do: config

  defp check_range(%{start: _, end: _} = dnsmasq), do: dnsmasq

  defp check_range(%{start: _} = dnsmasq),
    do: raise(ArgumentError, "dnsmasq :start needs an :end in #{inspect(dnsmasq)}")

  defp check_range(%{end: _} = dnsmasq),
    do: raise(ArgumentError, "dnsmasq :end needs a :start in #{inspect(dnsmasq)}")

  defp check_range(dnsmasq), do: dnsmasq

  defp check_lease_time(%{lease_time: lease_time} = dnsmasq)
       when lease_time == :infinite or (is_integer(lease_time) and lease_time > 0),
       do: dnsmasq

  defp check_lease_time(%{lease_time: lease_time}),
    do: raise(ArgumentError, "Invalid dnsmasq :lease_time #{inspect(lease_time)}")

  defp check_lease_time(dnsmasq), do: dnsmasq

  defp check_hosts_dir(%{hosts_dir: hosts_dir} = dnsmasq) when is_binary(hosts_dir), do: dnsmasq

  defp check_hosts_dir(%{hosts_dir: hosts_dir}),
    do: raise(ArgumentError, "Invalid dnsmasq :hosts_dir #{inspect(hosts_dir)}")

  defp check_hosts_dir(dnsmasq), do: dnsmasq

  @doc false
  @spec normalize_static_leases([tuple()]) :: [tuple()]
  def normalize_static_leases(leases), do: Enum.map(leases, &normalize_lease/1)

  defp normalize_lease({mac, ip}), do: {check_mac(mac), IP.ip_to_tuple!(ip)}

  defp normalize_lease({mac, ip, hostname}),
    do: {check_mac(mac), IP.ip_to_tuple!(ip), check_hostname(hostname)}

  defp check_mac(mac) do
    if is_binary(mac) and mac =~ ~r/\A[[:xdigit:]]{2}(:[[:xdigit:]]{2}){5}\z/ do
      mac
    else
      raise ArgumentError, "Invalid MAC address #{inspect(mac)}"
    end
  end

  defp check_hostname(hostname) do
    if is_binary(hostname) and hostname =~ ~r/\A[[:alnum:]]([[:alnum:]-]*[[:alnum:]])?\z/ do
      hostname
    else
      raise ArgumentError, "Invalid hostname #{inspect(hostname)}"
    end
  end

  defp normalize_record({name, ip}) do
    if is_binary(name) and name =~ ~r/\A[^\s\/#]+\z/ do
      {name, IP.ip_to_tuple!(ip)}
    else
      raise ArgumentError, "Invalid dnsmasq record name #{inspect(name)}"
    end
  end

  @doc """
  Add the dnsmasq configuration file and daemon
  """
  @spec add_config(RawConfig.t(), map(), keyword()) :: RawConfig.t()
  def add_config(
        %RawConfig{ifname: ifname} = raw_config,
        %{
          ipv4: %{method: :static, address: address, prefix_length: prefix_length},
          dnsmasq: dnsmasq
        },
        opts
      ) do
    tmpdir = Keyword.fetch!(opts, :tmpdir)
    conf_path = Path.join(tmpdir, "dnsmasq.conf.#{ifname}")
    lease_path = Path.join(tmpdir, "dnsmasq.#{ifname}.leases")
    notify_name = "dnsmasqex_#{ifname}"

    hosts_path = hosts_path(tmpdir, ifname)

    contents =
      dnsmasq_contents(dnsmasq, %{
        ifname: ifname,
        address: address,
        pid_path: pid_path(tmpdir, ifname),
        lease_path: lease_path,
        hosts_path: hosts_path
      })

    context = %{
      ifname: ifname,
      address: address,
      prefix_length: prefix_length,
      lease_path: lease_path
    }

    notifier =
      Supervisor.child_spec(
        {BEAMNotify,
         name: notify_name, report_env: true, dispatcher: &Notifications.dispatch(&1, &2, context)},
        id: :dnsmasq_notify
      )

    daemon =
      Supervisor.child_spec(
        {Daemon,
         ifname: ifname,
         command: dnsmasq_path(),
         args: ["-k", "-C", conf_path, "--log-facility=-"],
         opts: [
           env: BEAMNotify.env(name: notify_name),
           stderr_to_stdout: true,
           log_output: :debug
         ]},
        id: :dnsmasq
      )

    %{
      raw_config
      | files: [
          {conf_path, contents},
          {hosts_path, hosts_contents(dnsmasq.static_leases)} | raw_config.files
        ],
        child_specs: raw_config.child_specs ++ [notifier, daemon],
        down_cmds: raw_config.down_cmds ++ [{:fun, Notifications, :clear, [ifname]}]
    }
  end

  def add_config(raw_config, _config_without_dnsmasq, _opts), do: raw_config

  defp dnsmasq_contents(dnsmasq, %{
         ifname: ifname,
         address: address,
         pid_path: pid_path,
         lease_path: lease_path,
         hosts_path: hosts_path
       }) do
    [
      "interface=#{ifname}",
      "except-interface=lo",
      "listen-address=#{IP.ip_to_string(address)}",
      "bind-interfaces",
      "no-hosts",
      "user=root",
      "pid-file=#{pid_path}",
      "dhcp-leasefile=#{lease_path}",
      "dhcp-script=#{BEAMNotify.bin_path()}",
      "script-arp",
      "script-on-renewal",
      dhcp_range(dnsmasq),
      "dhcp-hostsfile=#{hosts_path}",
      hosts_dir(dnsmasq),
      Enum.map(dnsmasq.records, fn {name, ip} -> "address=/#{name}/#{IP.ip_to_string(ip)}" end)
    ]
    |> List.flatten()
    |> Enum.map_join(&[&1, "\n"])
  end

  defp dhcp_range(%{start: first, end: last} = dnsmasq) do
    fields = [IP.ip_to_string(first), IP.ip_to_string(last) | lease_time(dnsmasq[:lease_time])]
    "dhcp-range=" <> Enum.join(fields, ",")
  end

  defp dhcp_range(_dns_only), do: []

  defp hosts_dir(%{hosts_dir: hosts_dir}), do: "dhcp-hostsdir=#{hosts_dir}"
  defp hosts_dir(_dnsmasq), do: []

  @doc false
  @spec hosts_contents([tuple()]) :: String.t()
  def hosts_contents(static_leases) do
    Enum.map_join(static_leases, fn lease ->
      Enum.map_join(Tuple.to_list(lease), ",", &host_field/1) <> ",infinite\n"
    end)
  end

  defp host_field(ip) when is_tuple(ip), do: IP.ip_to_string(ip)
  defp host_field(field), do: field

  @doc false
  @spec hosts_path(Path.t(), VintageNet.ifname()) :: Path.t()
  def hosts_path(tmpdir, ifname), do: Path.join(tmpdir, "dnsmasq.#{ifname}.hosts")

  @doc false
  @spec pid_path(Path.t(), VintageNet.ifname()) :: Path.t()
  def pid_path(tmpdir, ifname), do: Path.join(tmpdir, "dnsmasq.#{ifname}.pid")

  defp lease_time(nil), do: []
  defp lease_time(:infinite), do: ["infinite"]
  defp lease_time(seconds), do: [Integer.to_string(seconds)]

  @doc false
  @spec dnsmasq_path() :: String.t()
  def dnsmasq_path(), do: Application.get_env(:dnsmasqex, :dnsmasq, "dnsmasq")
end
