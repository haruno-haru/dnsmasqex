# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.Server do
  @moduledoc false

  # Holds the static leases, DHCP options and records dnsmasq is using, so each
  # change builds on the current values and they're applied one at a time
  use GenServer

  alias Dnsmasqex.Config
  alias Dnsmasqex.IPv6

  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: via_name(Keyword.fetch!(args, :ifname)))
  end

  @spec update(VintageNet.ifname(), atom(), list()) :: :ok | {:error, any()}
  def update(ifname, command, args), do: call(ifname, {:update, command, args})

  @spec reload(VintageNet.ifname()) :: :ok | {:error, any()}
  def reload(ifname), do: call(ifname, :reload)

  defp call(ifname, request) do
    GenServer.call(via_name(ifname), request)
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
  end

  defp via_name(ifname),
    do: {:via, Registry, {VintageNet.Interface.Registry, {__MODULE__, ifname}}}

  @impl GenServer
  def init(args) do
    config = Keyword.fetch!(args, :config)

    state = %{
      ifname: Keyword.fetch!(args, :ifname),
      tmpdir: Keyword.fetch!(args, :tmpdir),
      config: config,
      dhcp_enabled?: Config.dhcp_enabled?(config.dnsmasq),
      dhcpv6_enabled?: IPv6.dhcp_enabled?(config.dnsmasq)
    }

    # Rewrite the files too, since they may hold changes from before a restart
    for option <- Config.runtime_options() do
      :ok = write_file(state, option)
      publish(state, option)
    end

    with {:error, reason} <- signal(state) do
      Logger.warning("[dnsmasqex(#{state.ifname})] Can't reload dnsmasq: #{reason}")
    end

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:update, command, args}, _from, state) do
    with {:ok, option, value} <- change(command, args, state),
         new_state = put_in(state.config.dnsmasq[option], value),
         :ok <- write_file(new_state, option) do
      publish(new_state, option)
      {:reply, signal(new_state), new_state}
    else
      error -> {:reply, error, state}
    end
  rescue
    e in ArgumentError -> {:reply, {:error, Exception.message(e)}, state}
  end

  def handle_call(:reload, _from, state) do
    reply = with {:ok, pid} <- running_dnsmasq(state), do: hangup(pid)
    {:reply, reply, state}
  end

  @lease_commands [:static_leases, :add_static_lease, :put_static_lease, :remove_static_lease]

  defp change(command, _args, %{dhcp_enabled?: false}) when command in @lease_commands,
    do: {:error, :dhcp_disabled}

  @lease6_commands [
    :static_leases6,
    :add_static_lease6,
    :put_static_lease6,
    :remove_static_lease6
  ]

  defp change(command, _args, %{dhcpv6_enabled?: false}) when command in @lease6_commands,
    do: {:error, :dhcpv6_disabled}

  defp change(option, [value], state)
       when option in [:static_leases, :options, :records, :static_leases6, :options6],
       do: {:ok, option, normalize(state, option, value)}

  defp change(command, [lease], state) when command in [:add_static_lease6, :put_static_lease6] do
    [lease] = normalize(state, :static_leases6, [lease])
    leases = state.config.dnsmasq.static_leases6

    others =
      if command == :put_static_lease6,
        do: Enum.reject(leases, &(&1.duid == lease.duid)),
        else: leases

    with :ok <- check_unused(others, lease, :duid_in_use, & &1.duid),
         :ok <- check_unused(others, lease, :ip_in_use, & &1.ip) do
      {:ok, :static_leases6, normalize(state, :static_leases6, others ++ [lease])}
    end
  end

  defp change(:remove_static_lease6, [duid], state) when is_binary(duid) do
    leases = Enum.reject(state.config.dnsmasq.static_leases6, &(&1.duid == String.downcase(duid)))
    {:ok, :static_leases6, leases}
  end

  defp change(:add_static_lease, [lease], state) do
    [lease] = normalize(state, :static_leases, [lease])
    leases = state.config.dnsmasq.static_leases

    with :ok <- check_unused(leases, lease, :mac_in_use, &Config.lease_mac/1),
         :ok <- check_unused(leases, lease, :ip_in_use, &Config.lease_ip/1) do
      {:ok, :static_leases, normalize(state, :static_leases, leases ++ [lease])}
    end
  end

  defp change(:put_static_lease, [lease], state) do
    [lease] = normalize(state, :static_leases, [lease])
    others = other_leases(state.config.dnsmasq.static_leases, lease)

    with :ok <- check_unused(others, lease, :ip_in_use, &Config.lease_ip/1) do
      {:ok, :static_leases, normalize(state, :static_leases, others ++ [lease])}
    end
  end

  defp change(:remove_static_lease, [mac], state) when is_binary(mac) do
    mac = String.downcase(mac)
    leases = Enum.reject(state.config.dnsmasq.static_leases, &(Config.lease_mac(&1) == mac))
    {:ok, :static_leases, leases}
  end

  defp change(:add_record, [{name, ips}], state) when ips not in [nil, []] do
    new_records = normalize(state, :records, for(ip <- List.wrap(ips), do: {name, ip}))
    records = state.config.dnsmasq.records

    case Enum.filter(records, &same_name?(&1, name)) do
      [] -> {:ok, :records, records ++ new_records}
      existing -> {:error, {:name_in_use, existing}}
    end
  end

  defp change(:put_record, [{name, ips}], state) when ips not in [nil, []] do
    new_records = normalize(state, :records, for(ip <- List.wrap(ips), do: {name, ip}))
    {:ok, :records, remove_name(state.config.dnsmasq.records, name) ++ new_records}
  end

  defp change(:remove_record, [name], state) when is_binary(name),
    do: {:ok, :records, remove_name(state.config.dnsmasq.records, name)}

  defp change(:put_option, [key, value], state) do
    options = Map.put(state.config.dnsmasq.options, key, value)
    {:ok, :options, normalize(state, :options, options)}
  end

  defp change(:delete_option, [key], state),
    do: {:ok, :options, Map.drop(state.config.dnsmasq.options, [key | option_aliases(key)])}

  defp change(:put_option6, [key, value], state) do
    options = Map.put(state.config.dnsmasq.options6, key, value)
    {:ok, :options6, normalize(state, :options6, options)}
  end

  defp change(:delete_option6, [key], state),
    do: {:ok, :options6, Map.delete(state.config.dnsmasq.options6, key)}

  defp change(command, args, _state),
    do: {:error, "Invalid dnsmasq ioctl #{inspect(command)} #{inspect(args)}"}

  defp normalize(state, option, value), do: Config.normalize_value(state.config, option, value)

  defp other_leases(leases, lease),
    do: Enum.reject(leases, &(Config.lease_mac(&1) == Config.lease_mac(lease)))

  defp check_unused(leases, lease, reason, key) do
    case key.(lease) && Enum.find(leases, &(key.(&1) == key.(lease))) do
      nil -> :ok
      existing -> {:error, {reason, existing}}
    end
  end

  defp remove_name(records, name), do: Enum.reject(records, &same_name?(&1, name))

  defp same_name?({existing, _ip}, name), do: String.downcase(existing) == String.downcase(name)

  defp option_aliases(:subnet), do: [:netmask]
  defp option_aliases(:netmask), do: [:subnet]
  defp option_aliases(_key), do: []

  defp write_file(state, option) do
    {path, contents} =
      Config.runtime_file(option, state.config.dnsmasq, state.tmpdir, state.ifname)

    temporary_path = path <> ".new"

    with :ok <- File.write(temporary_path, contents), do: File.rename(temporary_path, path)
  end

  defp publish(state, option) do
    PropertyTable.put(
      VintageNet,
      ["interface", state.ifname, "dnsmasq", Atom.to_string(option)],
      Map.fetch!(state.config.dnsmasq, option)
    )
  end

  defp signal(state) do
    case running_dnsmasq(state) do
      {:ok, pid} -> hangup(pid)
      {:error, :not_running} -> :ok
    end
  end

  defp running_dnsmasq(state) do
    conf_path = Config.conf_path(state.tmpdir, state.ifname)

    with {:ok, contents} <- File.read(Config.pid_path(state.tmpdir, state.ifname)),
         {pid, ""} when pid > 0 <- Integer.parse(String.trim(contents)),
         {:ok, cmdline} <- File.read("/proc/#{pid}/cmdline"),
         true <-
           ["-C", conf_path] in Enum.chunk_every(String.split(cmdline, "\0"), 2, 1, :discard) do
      {:ok, pid}
    else
      _ -> {:error, :not_running}
    end
  end

  defp hangup(pid) do
    case System.cmd("kill", ["-HUP", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, String.trim(output)}
    end
  end
end
