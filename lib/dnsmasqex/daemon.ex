# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.Daemon do
  @moduledoc false

  # Wraps MuonTrap.Daemon so that a program that keeps exiting backs off instead
  # of exhausting its supervisors and taking VintageNet down with them
  use GenServer
  require Logger

  @min_backoff 1_000
  @max_backoff 30_000
  @reset_after 30_000

  @type init_args :: [
          ifname: VintageNet.ifname(),
          command: binary(),
          args: [binary()],
          opts: keyword()
        ]

  @enforce_keys [:ifname, :command, :args]
  defstruct [:ifname, :command, :args, :pid, :started_at, opts: [], backoff: @min_backoff]

  @spec start_link(init_args()) :: GenServer.on_start()
  def start_link(init_args) do
    GenServer.start_link(__MODULE__, init_args)
  end

  @impl GenServer
  def init(init_args) do
    Process.flag(:trap_exit, true)
    state = struct!(__MODULE__, init_args)
    {:ok, state, {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, state), do: {:noreply, start_daemon(state)}

  @impl GenServer
  def handle_info(:restart, state), do: {:noreply, start_daemon(state)}

  def handle_info({:EXIT, pid, reason}, %{pid: pid} = state),
    do: {:noreply, schedule_restart(state, reason)}

  # Before OTP 26, a failed start_link also sends the exit of the process that failed
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp start_daemon(state) do
    Logger.debug("[dnsmasqex(#{state.ifname})] starting #{state.command}")

    case MuonTrap.Daemon.start_link(state.command, state.args, state.opts) do
      {:ok, pid} -> %{state | pid: pid, started_at: System.monotonic_time(:millisecond)}
      {:error, reason} -> schedule_restart(state, reason)
    end
  end

  defp schedule_restart(state, reason) do
    backoff = if ran_long_enough?(state), do: @min_backoff, else: state.backoff

    Logger.error(
      "[dnsmasqex(#{state.ifname})] #{state.command} stopped (#{inspect(reason)}). Restarting in #{backoff} ms"
    )

    Process.send_after(self(), :restart, backoff)
    %{state | pid: nil, started_at: nil, backoff: min(backoff * 2, @max_backoff)}
  end

  defp ran_long_enough?(%{started_at: nil}), do: false

  defp ran_long_enough?(%{started_at: started_at}),
    do: System.monotonic_time(:millisecond) - started_at >= @reset_after
end
