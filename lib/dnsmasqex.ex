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
  @spec capabilities() :: {:ok, capabilities()} | {:error, String.t()}
  def capabilities() do
    dnsmasq = Config.dnsmasq_path()

    case System.find_executable(dnsmasq) do
      nil -> {:error, "Can't find #{dnsmasq}"}
      path -> path |> System.cmd(["--version"], stderr_to_stdout: true) |> parse_version()
    end
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

  @runtime_options Config.runtime_options()

  defp run_ioctl(ifname, option, [value], %{dnsmasq: dnsmasq} = config)
       when option in @runtime_options do
    %{dnsmasq: new_dnsmasq} =
      Config.normalize(%{config | dnsmasq: Map.put(dnsmasq, option, value)})

    if option == :static_leases and not Config.dhcp_enabled?(dnsmasq) do
      {:error, :dhcp_disabled}
    else
      :global.trans(
        {{__MODULE__, ifname}, self()},
        fn -> update_runtime_file(ifname, option, new_dnsmasq) end,
        [node()]
      )
    end
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

  defp run_ioctl(ifname, :reload, _args, %{dnsmasq: _}) do
    with {:ok, pid} <- running_dnsmasq(ifname), do: reload(pid)
  end

  defp run_ioctl(ifname, command, args, %{technology: technology}),
    do: technology.ioctl(ifname, command, args)

  defp update_runtime_file(ifname, option, dnsmasq) do
    {path, contents} = Config.runtime_file(option, dnsmasq, tmpdir(), ifname)
    temporary_path = path <> ".new"

    with {:ok, pid} <- running_dnsmasq(ifname),
         :ok <- File.write(temporary_path, contents),
         :ok <- File.rename(temporary_path, path) do
      reload(pid)
    end
  end

  defp running_dnsmasq(ifname) do
    conf_path = Config.conf_path(tmpdir(), ifname)

    with {:ok, contents} <- File.read(Config.pid_path(tmpdir(), ifname)),
         {pid, ""} when pid > 0 <- Integer.parse(String.trim(contents)),
         {:ok, cmdline} <- File.read("/proc/#{pid}/cmdline"),
         true <-
           ["-C", conf_path] in Enum.chunk_every(String.split(cmdline, "\0"), 2, 1, :discard) do
      {:ok, pid}
    else
      _ -> {:error, :not_running}
    end
  end

  defp reload(pid) do
    case System.cmd("kill", ["-HUP", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, String.trim(output)}
    end
  end

  defp tmpdir(), do: Application.fetch_env!(:vintage_net, :tmpdir)
end
