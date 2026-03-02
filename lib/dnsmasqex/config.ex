# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.Config do
  @moduledoc """
  Run dnsmasq as the DHCP and DNS server on a static IPv4 interface

  This follows `VintageNet.IP.DhcpdConfig` and `VintageNet.IP.DnsdConfig`.
  Unlike dnsd, dnsmasq forwards names it doesn't know to the name servers in
  `/etc/resolv.conf`, so clients can use it as their only DNS server.

  The `:dnsmasq` key supports:

  * `:start` and `:end` - the DHCP address range. Without them, dnsmasq only
    serves DNS
  * `:lease_time` - seconds or `:infinite`. Defaults to dnsmasq's 1 hour
  * `:static_leases` - `{mac, ip}` pairs that always get the same address,
    with an infinite lease
  * `:records` - `{name, ip}` pairs answered locally, including subdomains

  Leases are published to `["interface", ifname, "dhcpd", "leases"]` in the
  same shape as udhcpd's, except that `:leasetime` is `:infinity` for
  infinite leases.
  """

  alias VintageNet.Interface.RawConfig
  alias VintageNet.IP
  alias Dnsmasqex.Leases

  @doc """
  Normalize the `:dnsmasq` options
  """
  @spec normalize(map()) :: map()
  def normalize(%{ipv4: %{method: :static}, dnsmasq: dnsmasq} = config) do
    new_dnsmasq =
      dnsmasq
      |> Map.take([:start, :end, :lease_time, :static_leases, :records])
      |> normalize_ip(:start)
      |> normalize_ip(:end)
      |> Map.update(:static_leases, [], &normalize_pairs/1)
      |> Map.update(:records, [], &normalize_pairs/1)

    %{config | dnsmasq: new_dnsmasq}
  end

  def normalize(%{dnsmasq: _not_static} = config), do: Map.drop(config, [:dnsmasq])
  def normalize(config), do: config

  defp normalize_pairs(pairs), do: Enum.map(pairs, fn {key, ip} -> {key, IP.ip_to_tuple!(ip)} end)

  defp normalize_ip(dnsmasq, key) do
    case dnsmasq do
      %{^key => ip} -> %{dnsmasq | key => IP.ip_to_tuple!(ip)}
      _ -> dnsmasq
    end
  end

  @doc """
  Add the dnsmasq configuration file and daemon
  """
  @spec add_config(RawConfig.t(), map(), keyword()) :: RawConfig.t()
  def add_config(
        %RawConfig{ifname: ifname} = raw_config,
        %{ipv4: %{method: :static, address: address}, dnsmasq: dnsmasq},
        opts
      ) do
    tmpdir = Keyword.fetch!(opts, :tmpdir)
    conf_path = Path.join(tmpdir, "dnsmasq.conf.#{ifname}")
    lease_path = Path.join(tmpdir, "dnsmasq.#{ifname}.leases")
    notify_name = "dnsmasqex_#{ifname}"

    contents =
      dnsmasq_contents(dnsmasq,
        ifname: ifname,
        address: address,
        pid_path: Path.join(tmpdir, "dnsmasq.#{ifname}.pid"),
        lease_path: lease_path
      )

    notifier =
      Supervisor.child_spec(
        {BEAMNotify,
         name: notify_name, dispatcher: fn _args, _env -> Leases.update(ifname, lease_path) end},
        id: :dnsmasq_notify
      )

    daemon =
      Supervisor.child_spec(
        {MuonTrap.Daemon,
         [
           dnsmasq_path(),
           ["-k", "-C", conf_path, "--log-facility=-"],
           [env: BEAMNotify.env(name: notify_name), stderr_to_stdout: true, log_output: :debug]
         ]},
        id: :dnsmasq
      )

    %{
      raw_config
      | files: [{conf_path, contents} | raw_config.files],
        child_specs: raw_config.child_specs ++ [notifier, daemon],
        down_cmds: raw_config.down_cmds ++ [{:fun, Leases, :clear, [ifname]}]
    }
  end

  def add_config(raw_config, _config_without_dnsmasq, _opts), do: raw_config

  @doc false
  @spec dnsmasq_contents(map(), keyword()) :: String.t()
  def dnsmasq_contents(dnsmasq, opts) do
    [
      "interface=#{opts[:ifname]}",
      "except-interface=lo",
      "listen-address=#{IP.ip_to_string(opts[:address])}",
      "bind-interfaces",
      "no-hosts",
      "user=root",
      "pid-file=#{opts[:pid_path]}",
      "dhcp-leasefile=#{opts[:lease_path]}",
      "dhcp-script=#{BEAMNotify.bin_path()}",
      dhcp_range(dnsmasq),
      Enum.map(dnsmasq.static_leases, fn {mac, ip} ->
        "dhcp-host=#{mac},#{IP.ip_to_string(ip)},infinite"
      end),
      Enum.map(dnsmasq.records, fn {name, ip} -> "address=/#{name}/#{IP.ip_to_string(ip)}" end)
    ]
    |> List.flatten()
    |> Enum.map_join(&[&1, "\n"])
  end

  defp dhcp_range(%{start: first, end: last} = dnsmasq) do
    "dhcp-range=#{IP.ip_to_string(first)},#{IP.ip_to_string(last)}" <>
      lease_time(dnsmasq[:lease_time])
  end

  defp dhcp_range(_dns_only), do: []

  defp lease_time(nil), do: ""
  defp lease_time(:infinite), do: ",infinite"
  defp lease_time(seconds), do: ",#{seconds}"

  @doc false
  @spec dnsmasq_path() :: String.t()
  def dnsmasq_path(), do: Application.get_env(:dnsmasqex, :dnsmasq, "dnsmasq")
end
