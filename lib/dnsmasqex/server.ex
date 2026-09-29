# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.Server do
  @moduledoc false

  use GenServer

  alias Dnsmasqex.Config
  alias Dnsmasqex.Daemon
  alias Dnsmasqex.Directives
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

  @spec dump_stats(VintageNet.ifname()) :: :ok | {:error, term()}
  def dump_stats(ifname), do: call(ifname, :dump_stats)

  @spec dns_endpoint(VintageNet.ifname()) ::
          {:ok, {:inet.ip_address(), pos_integer()}} | {:error, term()}
  def dns_endpoint(ifname), do: call(ifname, :dns_endpoint)

  @spec preflight_config(VintageNet.ifname()) ::
          {:ok, [atom()], [{atom(), Path.t()}]} | {:error, term()}
  def preflight_config(ifname), do: call(ifname, :preflight_config)

  defp call(ifname, request) do
    GenServer.call(via_name(ifname), request, 180_000)
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
      startup_dhcp_services?: Config.dhcp_services?(config.dnsmasq),
      startup_dhcp_enabled?:
        match?(%{ipv4: %{method: :static}}, config) and Config.dhcp_enabled?(config.dnsmasq),
      startup_dhcpv6_enabled?: IPv6.dhcp_enabled?(config.dnsmasq)
    }

    {native_path, native_contents} =
      Config.runtime_file(:directives, config.dnsmasq, state.tmpdir, state.ifname)

    native_changed? = File.read(native_path) != {:ok, native_contents}

    Enum.each(Config.runtime_options(), fn option ->
      :ok = write_file(state, option)
      :ok = publish(state, option)
    end)

    case signal(state, if(native_changed?, do: "TERM", else: "HUP")) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[dnsmasqex(#{state.ifname})] Can't signal dnsmasq: #{inspect(reason)}")
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

      operation = if option == :directives, do: "TERM", else: "HUP"
      {:reply, apply_update(new_state, option, operation), new_state}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call(:reload, _from, state) do
    reply = with {:ok, pid} <- running_dnsmasq(state), do: send_signal(pid, "HUP")
    {:reply, reply, state}
  end

  def handle_call(:dump_stats, _from, state) do
    reply = with {:ok, pid} <- running_dnsmasq(state), do: send_signal(pid, "USR1")
    {:reply, reply, state}
  end

  def handle_call(:dns_endpoint, _from, state) do
    dnsmasq = state.config.dnsmasq
    port = Map.get(dnsmasq, :port, List.last(Keyword.get_values(dnsmasq.directives, :port)) || 53)
    address = get_in(state.config, [:ipv4, :address]) || get_in(state.config, [:ipv6, :address])

    reply =
      cond do
        port == 0 -> {:error, :dns_disabled}
        is_nil(address) -> {:error, :no_static_listen_address}
        true -> {:ok, {address, port}}
      end

    {:reply, reply, state}
  end

  def handle_call(:preflight_config, _from, state) do
    features = Config.required_features(state.config)
    features = if state.startup_dhcp_services?, do: [:dhcp, :scripts | features], else: features
    files = Config.validation_files(state.config, state.tmpdir, state.ifname)
    {:reply, {:ok, Enum.uniq(features), files}, state}
  end

  defp validate_change(command, args, state) do
    with {:ok, option, value} <- change(command, args, state),
         :ok <- validate_role(state, Map.put(state.config.dnsmasq, option, value)) do
      {:ok, option, value}
    end
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp validate_role(state, updated) do
    original = state.config.dnsmasq
    native_ranges? = Directives.enabled?(original.directives, :dhcp_range)

    if (not state.startup_dhcp_services? and Config.dhcp_services?(updated)) or
         state.startup_dhcp_enabled? != runtime_dhcp_enabled?(state, updated) or
         state.startup_dhcpv6_enabled? != IPv6.dhcp_enabled?(updated) or
         IPv6.ra_enabled?(original) != IPv6.ra_enabled?(updated) or
         native_ranges? != Directives.enabled?(updated.directives, :dhcp_range) or
         Keyword.get_values(original.directives, :user) !=
           Keyword.get_values(updated.directives, :user),
       do: {:error, :requires_interface_reconfiguration},
       else: :ok
  end

  defp runtime_dhcp_enabled?(state, dnsmasq) do
    generated_pool? =
      state.startup_dhcp_enabled? and not Directives.enabled?(dnsmasq.directives, :dhcp_range)

    match?(%{ipv4: %{method: :static}}, state.config) and
      (generated_pool? or Config.dhcp_enabled?(dnsmasq))
  end

  defp change(command, _args, %{startup_dhcp_enabled?: false}) when command in @lease_commands,
    do: {:error, :dhcp_disabled}

  defp change(command, _args, %{startup_dhcpv6_enabled?: false}) when command in @lease6_commands,
    do: {:error, :dhcpv6_disabled}

  defp change(command, _args, %{startup_dhcp_services?: false})
       when command in [:dhcp_hosts, :dhcp_options],
       do: {:error, :dhcp_disabled}

  defp change(option, [value], state)
       when option in [
              :static_leases,
              :options,
              :records,
              :static_leases6,
              :options6,
              :upstreams,
              :directives,
              :dhcp_hosts,
              :dhcp_options
            ],
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

    timeout = Map.get(state.config.dnsmasq, :preflight_timeout, 5_000)

    if option == :directives do
      Preflight.replacement(
        Config.dnsmasq_path(),
        Config.conf_path(state.tmpdir, state.ifname),
        Config.runtime_path(:directives, state.tmpdir, state.ifname),
        contents,
        Config.required_features(state.config),
        Config.validation_files(state.config, state.tmpdir, state.ifname),
        timeout
      )
    else
      Preflight.runtime(Config.dnsmasq_path(), option, contents, state.tmpdir, timeout)
    end
  end

  defp apply_update(state, option, operation) do
    {reply, status} =
      case running_dnsmasq(state) do
        {:ok, pid} ->
          case send_signal(pid, operation) do
            :ok -> {:ok, if(operation == "TERM", do: :restart_signaled, else: :reload_signaled)}
            {:error, reason} = error -> {error, {:signal_failed, reason}}
          end

        {:error, :not_running} ->
          Daemon.retry(state.ifname)
          {:ok, :pending_start}
      end

    PropertyTable.put(VintageNet, ["interface", state.ifname, "dnsmasq", "update"], %{
      option: option,
      state: status,
      saved: true
    })

    reply
  end

  defp publish(state, option) do
    PropertyTable.put(
      VintageNet,
      ["interface", state.ifname, "dnsmasq", Atom.to_string(option)],
      Map.fetch!(state.config.dnsmasq, option)
    )
  end

  defp signal(state, operation) do
    case running_dnsmasq(state) do
      {:ok, pid} -> send_signal(pid, operation)
      {:error, :not_running} -> Daemon.retry(state.ifname)
    end
  end

  defp running_dnsmasq(state) do
    Daemon.running_pid(
      Config.pid_path(state.tmpdir, state.ifname),
      Config.conf_path(state.tmpdir, state.ifname)
    )
  end

  defp send_signal(pid, signal) do
    case Dnsmasqex.Command.run("kill", ["-#{signal}", Integer.to_string(pid)], 1_000) do
      {_output, 0} -> :ok
      {:error, reason} -> {:error, inspect(reason)}
      {output, _status} -> {:error, String.trim(output)}
    end
  end
end
