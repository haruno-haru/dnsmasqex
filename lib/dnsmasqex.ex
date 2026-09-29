# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex do
  @moduledoc """
  Run dnsmasq on an interface managed by another technology

  See `Dnsmasqex.Config` for the `:dnsmasq` options.

  ```elixir
  %{
    type: Dnsmasqex,
    technology: VintageNetEthernet,
    ipv4: %{method: :static, address: "192.168.24.1", prefix_length: 24},
    dnsmasq: %{
      start: "192.168.24.10",
      end: "192.168.24.99",
      static_leases: [{"aa:bb:cc:dd:ee:ff", "192.168.24.100"}],
      records: [{"device.example.com", "192.168.24.1"}]
    }
  }
  ```
  """
  @behaviour VintageNet.Technology

  alias Dnsmasqex.Config
  alias Dnsmasqex.Server

  @impl VintageNet.Technology
  def normalize(%{type: __MODULE__, technology: __MODULE__}),
    do: raise(ArgumentError, "Dnsmasqex can't wrap itself")

  def normalize(%{type: __MODULE__, technology: technology} = config) do
    %{config | type: technology}
    |> technology.normalize()
    |> Map.merge(%{type: __MODULE__, technology: technology})
    |> Config.normalize()
  end

  def normalize(%{type: __MODULE__}),
    do: raise(ArgumentError, "Dnsmasqex needs the :technology that manages the interface")

  @impl VintageNet.Technology
  def to_raw_config(ifname, %{type: __MODULE__} = config, opts) do
    %{technology: technology} = normalized_config = normalize(config)
    raw_config = technology.to_raw_config(ifname, %{normalized_config | type: technology}, opts)

    Config.add_config(
      %{raw_config | type: __MODULE__, source_config: normalized_config},
      normalized_config,
      opts
    )
  end

  @impl VintageNet.Technology
  def ioctl(ifname, command, args) do
    run_ioctl(ifname, command, args, VintageNet.get_configuration(ifname))
  end

  @impl VintageNet.Technology
  def check_system(_opts) do
    case capabilities() do
      {:ok, %{dhcp: true, scripts: true}} -> :ok
      {:ok, _} -> {:error, "#{Config.dnsmasq_path()} was built without DHCP or script support"}
      error -> error
    end
  end

  @typedoc """
  The dnsmasq version and whether it was built with each feature
  """
  @type capabilities :: %{
          version: String.t(),
          ipv6: boolean(),
          dhcp: boolean(),
          dhcpv6: boolean(),
          scripts: boolean(),
          lua: boolean(),
          tftp: boolean(),
          auth: boolean(),
          dnssec: boolean(),
          ipset: boolean(),
          nftset: boolean(),
          conntrack: boolean(),
          dbus: boolean(),
          ubus: boolean(),
          i18n: boolean(),
          idn: boolean(),
          loop_detect: boolean(),
          inotify: boolean(),
          dumpfile: boolean()
        }

  @features [
    ipv6: ["IPv6"],
    dhcp: ["DHCP"],
    dhcpv6: ["DHCPv6"],
    lua: ["Lua"],
    tftp: ["TFTP"],
    auth: ["auth"],
    dnssec: ["DNSSEC"],
    ipset: ["ipset"],
    nftset: ["nftset"],
    conntrack: ["conntrack"],
    dbus: ["DBus"],
    ubus: ["UBus"],
    i18n: ["i18n"],
    idn: ["IDN", "IDN2"],
    loop_detect: ["loop-detect"],
    inotify: ["inotify"],
    dumpfile: ["dumpfile"]
  ]

  @doc """
  Report the dnsmasq version and the features it was built with

  For example, `:nftset` must be `true` to use the `:nftsets` option, and
  `:dnssec` to validate DNSSEC.
  """
  @spec capabilities(String.t()) :: {:ok, capabilities()} | {:error, String.t()}
  def capabilities(dnsmasq \\ Config.dnsmasq_path()) do
    case System.find_executable(dnsmasq) do
      nil ->
        {:error, "Can't find #{dnsmasq}"}

      path ->
        path
        |> System.cmd(["--version"], stderr_to_stdout: true, env: [{"LC_ALL", "C"}])
        |> parse_version()
    end
  rescue
    error in ErlangError -> {:error, "Can't execute #{dnsmasq}: #{inspect(error.original)}"}
  end

  defp parse_version({output, 0}) do
    with [_, version] <- Regex.run(~r/^Dnsmasq version (\S+)/m, output),
         [_, options] <- Regex.run(~r/^Compile time options: (.*)$/m, output) do
      options = String.split(options)

      features =
        Map.new(@features, fn {feature, names} ->
          {feature, Enum.any?(names, &(&1 in options))}
        end)

      {:ok, Map.merge(features, %{version: version, scripts: "no-scripts" not in options})}
    else
      _ -> {:error, "Unexpected dnsmasq --version output: #{inspect(output)}"}
    end
  end

  defp parse_version({output, _status}), do: {:error, String.trim(output)}

  @doc """
  Check whether the kernel has nf_tables, either built in or as a module

  dnsmasq needs it, and a `:nftset` build, to use the `:nftsets` option.
  """
  @spec nftables_available?() :: boolean()
  def nftables_available?(), do: nftables_available?("/")

  @doc false
  @spec nftables_available?(Path.t()) :: boolean()
  def nftables_available?(root),
    do: File.exists?(Path.join(root, "sys/module/nf_tables")) or nf_tables_module?(root)

  defp nf_tables_module?(root) do
    case File.read(Path.join(root, "proc/sys/kernel/osrelease")) do
      {:ok, release} ->
        modules = Path.join([root, "lib/modules", String.trim(release)])
        Enum.any?(["modules.builtin", "modules.dep"], &listed?(File.read(Path.join(modules, &1))))

      {:error, _} ->
        false
    end
  end

  defp listed?({:ok, modules}), do: modules =~ ~r{(^|/)nf_tables\.ko}m
  defp listed?({:error, _}), do: false

  @server_commands [
    :static_leases,
    :add_static_lease,
    :put_static_lease,
    :remove_static_lease,
    :static_leases6,
    :add_static_lease6,
    :put_static_lease6,
    :remove_static_lease6,
    :records,
    :add_record,
    :put_record,
    :remove_record,
    :options,
    :put_option,
    :delete_option,
    :options6,
    :put_option6,
    :delete_option6
  ]

  defp run_ioctl(ifname, :reload, _args, %{dnsmasq: _}), do: Server.reload(ifname)

  defp run_ioctl(ifname, command, args, %{dnsmasq: _}) when command in @server_commands,
    do: Server.update(ifname, command, args)

  defp run_ioctl(ifname, command, args, %{technology: technology}),
    do: technology.ioctl(ifname, command, args)
end
