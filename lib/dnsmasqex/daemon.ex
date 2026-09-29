# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.Daemon do
  @moduledoc false

  # Wraps MuonTrap.Daemon so that a program that keeps exiting backs off instead
  # of exhausting its supervisors and taking VintageNet down with them
  use GenServer
  alias Dnsmasqex.Preflight
  require Logger

  @min_backoff 1_000
  @max_backoff 30_000
  @reset_after 30_000

  @type init_args :: [
          ifname: VintageNet.ifname(),
          command: binary(),
          args: [binary()],
          opts: keyword(),
          config_path: Path.t(),
          pid_path: Path.t(),
          required_features: [atom()],
          runtime_files: [{atom(), Path.t()}]
        ]

  @enforce_keys [:ifname, :command, :args]
  defstruct [
    :ifname,
    :command,
    :args,
    :pid,
    :started_at,
    :config_path,
    :pid_path,
    opts: [],
    required_features: [],
    runtime_files: [],
    backoff: @min_backoff
  ]

  @spec start_link(init_args()) :: GenServer.on_start()
  def start_link(init_args) do
    GenServer.start_link(__MODULE__, init_args)
  end

  @impl GenServer
  def init(init_args) do
    Process.flag(:trap_exit, true)
    state = struct!(__MODULE__, init_args)
    publish(state, %{state: :starting})
    {:ok, state, {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, state), do: {:noreply, start_daemon(state)}

  @impl GenServer
  def handle_info(:restart, %{pid: nil} = state), do: {:noreply, start_daemon(state)}
  def handle_info(:restart, state), do: {:noreply, state}

  def handle_info({:check_started, pid}, %{pid: pid} = state) do
    _ =
      case running_pid(state.pid_path, state.config_path) do
        {:ok, os_pid} -> publish(state, %{state: :running, pid: os_pid})
        {:error, :not_running} -> Process.send_after(self(), {:check_started, pid}, 50)
      end

    {:noreply, state}
  end

  def handle_info({:check_started, _pid}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, reason}, %{pid: pid} = state),
    do: {:noreply, schedule_restart(state, reason)}

  # Before OTP 26, a failed start_link also sends the exit of the process that failed
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    if state.pid, do: Process.exit(state.pid, :shutdown)
    publish(state, %{state: :stopped})
    :ok
  end

  defp start_daemon(state) do
    publish(state, %{state: :starting})

    case preflight(state) do
      :ok ->
        launch(state)

      {:error, reason} ->
        Logger.error("[dnsmasqex(#{state.ifname})] Preflight failed: #{inspect(reason)}")
        publish(state, %{state: :failed, reason: reason})
        state
    end
  end

  defp preflight(%{config_path: nil}), do: :ok

  defp preflight(state),
    do:
      Preflight.check(
        state.command,
        state.config_path,
        state.required_features,
        state.runtime_files
      )

  defp launch(state) do
    Logger.debug("[dnsmasqex(#{state.ifname})] starting #{state.command}")
    _ = if state.pid_path, do: File.rm(state.pid_path)

    case MuonTrap.Daemon.start_link(state.command, state.args, state.opts) do
      {:ok, pid} ->
        _ = if state.pid_path, do: Process.send_after(self(), {:check_started, pid}, 50)
        %{state | pid: pid, started_at: System.monotonic_time(:millisecond)}

      {:error, reason} ->
        schedule_restart(state, reason)
    end
  end

  defp schedule_restart(state, reason) do
    backoff = if ran_long_enough?(state), do: @min_backoff, else: state.backoff

    Logger.error(
      "[dnsmasqex(#{state.ifname})] #{state.command} stopped (#{inspect(reason)}). Restarting in #{backoff} ms"
    )

    Process.send_after(self(), :restart, backoff)
    publish(state, %{state: :retrying, reason: reason, retry_in: backoff})
    %{state | pid: nil, started_at: nil, backoff: min(backoff * 2, @max_backoff)}
  end

  defp ran_long_enough?(%{started_at: nil}), do: false

  defp ran_long_enough?(%{started_at: started_at}),
    do: System.monotonic_time(:millisecond) - started_at >= @reset_after

  @spec running_pid(Path.t(), Path.t()) :: {:ok, pos_integer()} | {:error, :not_running}
  def running_pid(pid_path, config_path) do
    with {:ok, contents} <- File.read(pid_path),
         {pid, ""} when pid > 0 <- Integer.parse(String.trim(contents)),
         {:ok, cmdline} <- File.read("/proc/#{pid}/cmdline"),
         true <-
           ["-C", config_path] in Enum.chunk_every(String.split(cmdline, "\0"), 2, 1, :discard) do
      {:ok, pid}
    else
      _ -> {:error, :not_running}
    end
  end

  defp publish(state, status),
    do: PropertyTable.put(VintageNet, ["interface", state.ifname, "dnsmasq", "status"], status)
end
