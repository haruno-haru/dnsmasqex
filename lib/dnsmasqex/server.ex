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
  alias Dnsmasqex.Daemon
  alias Dnsmasqex.IPv6
  alias Dnsmasqex.Preflight

  require Logger

  @lease_commands [:static_leases, :add_static_lease, :put_static_lease, :remove_static_lease]
  @lease6_commands [
    :static_leases6,
    :add_static_lease6,
    :put_static_lease6,
    :remove_static_lease6
  ]

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
      dhcp_enabled?:
        match?(%{ipv4: %{method: :static}}, config) and Config.dhcp_enabled?(config.dnsmasq),
      dhcpv6_enabled?: IPv6.dhcp_enabled?(config.dnsmasq)
    }

    # Rewrite the files too, since they may hold changes from before a restart
    Enum.each(Config.runtime_options(), fn option ->
      :ok = write_file(state, option)
      :ok = publish(state, option)
    end)

    case signal(state) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[dnsmasqex(#{state.ifname})] Can't reload dnsmasq: #{reason}")
    end

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:update, command, args}, _from, state) do
    with {:ok, option, value} <- validate_change(command, args, state),
         new_state = put_in(state.config.dnsmasq[option], value),
         :ok <- validate_file(new_state, option),
         :ok <- write_file(new_state, option) do
      :ok = publish(new_state, option)
      {:reply, signal(new_state), new_state}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call(:reload, _from, state) do
    reply = with {:ok, pid} <- running_dnsmasq(state), do: hangup(pid)
    {:reply, reply, state}
  end

  # Only input validation errors become replies. Failures after writing a file
  # must not be reported as rejected input while retaining the previous state.
  defp validate_change(command, args, state) do
    change(command, args, state)
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp change(command, _args, %{dhcp_enabled?: false}) when command in @lease_commands,
    do: {:error, :dhcp_disabled}

  defp change(command, _args, %{dhcpv6_enabled?: false}) when command in @lease6_commands,
    do: {:error, :dhcpv6_disabled}

  defp change(option, [value], state)
       when option in [:static_leases, :options, :records, :static_leases6, :options6],
       do: {:ok, option, normalize(state, option, value)}

  defp change(:add_static_lease6, [lease], state) do
    [lease] = normalize(state, :static_leases6, [lease])
    leases = state.config.dnsmasq.static_leases6

    with :ok <- check_unused(leases, lease, :duid_in_use, & &1.duid),
         :ok <- check_unused(leases, lease, :ip_in_use, & &1.ip) do
      {:ok, :static_leases6, leases ++ [lease]}
    end
  end

  defp change(:put_static_lease6, [lease], state) do
    [lease] = normalize(state, :static_leases6, [lease])
    others = Enum.reject(state.config.dnsmasq.static_leases6, &(&1.duid == lease.duid))

    with :ok <- check_unused(others, lease, :ip_in_use, & &1.ip) do
      {:ok, :static_leases6, others ++ [lease]}
    end
  end

  defp change(:remove_static_lease6, [duid], state) when is_binary(duid) do
    duid = String.downcase(duid)
    leases = Enum.reject(state.config.dnsmasq.static_leases6, &(&1.duid == duid))
    {:ok, :static_leases6, leases}
  end

  defp change(:add_static_lease, [lease], state) do
    [lease] = normalize(state, :static_leases, [lease])
    leases = state.config.dnsmasq.static_leases

    with :ok <- check_unused(leases, lease, :mac_in_use, &Config.lease_mac/1),
         :ok <- check_unused(leases, lease, :ip_in_use, &Config.lease_ip/1) do
      {:ok, :static_leases, leases ++ [lease]}
    end
  end

  defp change(:put_static_lease, [lease], state) do
    [lease] = normalize(state, :static_leases, [lease])
    others = other_leases(state.config.dnsmasq.static_leases, lease)

    with :ok <- check_unused(others, lease, :ip_in_use, &Config.lease_ip/1) do
      {:ok, :static_leases, others ++ [lease]}
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
    number = Config.option_number(key)

    options =
      state.config.dnsmasq.options
      |> Map.reject(fn {existing, _value} -> Config.option_number(existing) == number end)
      |> Map.put(key, value)

    {:ok, :options, normalize(state, :options, options)}
  end

  defp change(:delete_option, [key], state) do
    number = Config.option_number(key)

    options =
      Map.reject(state.config.dnsmasq.options, fn {existing, _value} ->
        Config.option_number(existing) == number
      end)

    {:ok, :options, options}
  end

  defp change(:put_option6, [key, value], state) do
    number = IPv6.option_number(key)

    options =
      state.config.dnsmasq.options6
      |> Map.reject(fn {existing, _value} -> IPv6.option_number(existing) == number end)
      |> Map.put(key, value)

    {:ok, :options6, normalize(state, :options6, options)}
  end

  defp change(:delete_option6, [key], state) do
    number = IPv6.option_number(key)

    options =
      Map.reject(state.config.dnsmasq.options6, fn {existing, _value} ->
        IPv6.option_number(existing) == number
      end)

    {:ok, :options6, options}
  end

  defp change(command, args, _state),
    do: {:error, "Invalid dnsmasq ioctl #{inspect(command)} #{inspect(args)}"}

  defp normalize(state, option, value), do: Config.normalize_value(state.config, option, value)

  defp other_leases(leases, lease),
    do: Enum.reject(leases, &(Config.lease_mac(&1) == Config.lease_mac(lease)))

  defp check_unused(leases, lease, reason, key) do
    value = key.(lease)

    case value && Enum.find(leases, &(key.(&1) == value)) do
      nil -> :ok
      existing -> {:error, {reason, existing}}
    end
  end

  defp remove_name(records, name), do: Enum.reject(records, &same_name?(&1, name))

  defp same_name?({existing, _ip}, name), do: String.downcase(existing) == String.downcase(name)

  defp write_file(state, option) do
    {path, contents} =
      Config.runtime_file(option, state.config.dnsmasq, state.tmpdir, state.ifname)

    temporary_path = path <> ".new"

    with :ok <- File.write(temporary_path, contents), do: File.rename(temporary_path, path)
  end

  defp validate_file(state, option) do
    {_path, contents} =
      Config.runtime_file(option, state.config.dnsmasq, state.tmpdir, state.ifname)

    Preflight.runtime(Config.dnsmasq_path(), option, contents, state.tmpdir)
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
    Daemon.running_pid(
      Config.pid_path(state.tmpdir, state.ifname),
      Config.conf_path(state.tmpdir, state.ifname)
    )
  end

  defp hangup(pid) do
    case System.cmd("kill", ["-HUP", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, String.trim(output)}
    end
  end
end
