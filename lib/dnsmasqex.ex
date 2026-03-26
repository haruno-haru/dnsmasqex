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
    dnsmasq = Config.dnsmasq_path()

    if System.find_executable(dnsmasq) do
      :ok
    else
      {:error, "Can't find #{dnsmasq}"}
    end
  end

  defp run_ioctl(ifname, :static_leases, [leases], %{dnsmasq: dnsmasq} = config) do
    %{dnsmasq: %{static_leases: static_leases}} =
      Config.normalize(%{config | dnsmasq: %{dnsmasq | static_leases: leases}})

    with {:ok, pid} <- running_dnsmasq(ifname) do
      File.write!(Config.hosts_path(tmpdir(), ifname), Config.hosts_contents(static_leases))
      reload(pid)
    end
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

  defp run_ioctl(ifname, :reload, _args, %{dnsmasq: _}) do
    with {:ok, pid} <- running_dnsmasq(ifname), do: reload(pid)
  end

  defp run_ioctl(ifname, command, args, %{technology: technology}),
    do: technology.ioctl(ifname, command, args)

  # Check the process before signaling it since the pid may have been reused
  defp running_dnsmasq(ifname) do
    conf_path = Config.conf_path(tmpdir(), ifname)

    with {:ok, pid} <- File.read(Config.pid_path(tmpdir(), ifname)),
         pid = String.trim(pid),
         {:ok, cmdline} <- File.read("/proc/#{pid}/cmdline"),
         true <- String.contains?(cmdline, conf_path) do
      {:ok, pid}
    else
      _ -> {:error, :not_running}
    end
  end

  defp reload(pid) do
    case System.cmd("kill", ["-HUP", pid], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, String.trim(output)}
    end
  end

  defp tmpdir(), do: Application.fetch_env!(:vintage_net, :tmpdir)
end
