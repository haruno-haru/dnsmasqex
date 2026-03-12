# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.Config do
  @moduledoc """
  dnsmasq options for a static IPv4 interface

  * `:start` and `:end` - DHCP address range. Omit them for DNS only
  * `:lease_time` - seconds or `:infinite`
  * `:static_leases` - `{mac, ip}` pairs with infinite leases
  * `:records` - `{name, ip}` pairs, including their subdomains

  Other names are forwarded to the name servers in `/etc/resolv.conf`.
  """

  alias VintageNet.Interface.RawConfig
  alias VintageNet.IP
  alias Dnsmasqex.Daemon
  alias Dnsmasqex.Leases

  @doc """
  Normalize the `:dnsmasq` options
  """
  @spec normalize(map()) :: map()
  def normalize(%{ipv4: %{method: :static}, dnsmasq: dnsmasq} = config) do
    new_dnsmasq =
      dnsmasq
      |> Map.take([:start, :end, :lease_time, :static_leases, :records])
      |> check_range()
      |> check_lease_time()
      |> Map.replace_lazy(:start, &IP.ip_to_tuple!/1)
      |> Map.replace_lazy(:end, &IP.ip_to_tuple!/1)
      |> Map.update(:static_leases, [], fn leases -> Enum.map(leases, &normalize_lease/1) end)
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

  defp normalize_lease({mac, ip}) do
    if is_binary(mac) and mac =~ ~r/\A[[:xdigit:]]{2}(:[[:xdigit:]]{2}){5}\z/ do
      {mac, IP.ip_to_tuple!(ip)}
    else
      raise ArgumentError, "Invalid MAC address #{inspect(mac)}"
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
        %{ipv4: %{method: :static, address: address}, dnsmasq: dnsmasq},
        opts
      ) do
    tmpdir = Keyword.fetch!(opts, :tmpdir)
    conf_path = Path.join(tmpdir, "dnsmasq.conf.#{ifname}")
    lease_path = Path.join(tmpdir, "dnsmasq.#{ifname}.leases")
    notify_name = "dnsmasqex_#{ifname}"

    contents =
      dnsmasq_contents(dnsmasq, %{
        ifname: ifname,
        address: address,
        pid_path: Path.join(tmpdir, "dnsmasq.#{ifname}.pid"),
        lease_path: lease_path
      })

    notifier =
      Supervisor.child_spec(
        {BEAMNotify,
         name: notify_name, dispatcher: fn _args, _env -> Leases.update(ifname, lease_path) end},
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
      | files: [{conf_path, contents} | raw_config.files],
        child_specs: raw_config.child_specs ++ [notifier, daemon],
        down_cmds: raw_config.down_cmds ++ [{:fun, Leases, :clear, [ifname]}]
    }
  end

  def add_config(raw_config, _config_without_dnsmasq, _opts), do: raw_config

  defp dnsmasq_contents(dnsmasq, %{
         ifname: ifname,
         address: address,
         pid_path: pid_path,
         lease_path: lease_path
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
    fields = [IP.ip_to_string(first), IP.ip_to_string(last) | lease_time(dnsmasq[:lease_time])]
    "dhcp-range=" <> Enum.join(fields, ",")
  end

  defp dhcp_range(_dns_only), do: []

  defp lease_time(nil), do: []
  defp lease_time(:infinite), do: ["infinite"]
  defp lease_time(seconds), do: [Integer.to_string(seconds)]

  @doc false
  @spec dnsmasq_path() :: String.t()
  def dnsmasq_path(), do: Application.get_env(:dnsmasqex, :dnsmasq, "dnsmasq")
end
