# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.Command do
  @moduledoc false

  # Probes have small, bounded output. Reading one fixed window avoids writing
  # flow-control acknowledgments to a short-lived process after it has exited.
  # The MuonTrap executable still terminates the child when its port closes.
  @output_limit 65_536

  @spec run(String.t(), [String.t()], pos_integer()) ::
          {String.t(), non_neg_integer() | :timeout} | {:error, term()}
  def run(command, args, timeout) do
    case System.find_executable(command) do
      nil -> {:error, :enoent}
      path -> execute(path, args, timeout)
    end
  end

  defp execute(path, args, timeout) do
    port =
      Port.open({:spawn_executable, MuonTrap.muontrap_path()}, [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        :stderr_to_stdout,
        env: [{~c"LC_ALL", ~c"C"}],
        args:
          [
            "--capture-output",
            "--capture-stderr",
            "--stdio-window",
            "#{@output_limit}",
            "--",
            path
          ] ++
            args
      ])

    try do
      receive_output(port, "", System.monotonic_time(:millisecond) + timeout)
    after
      close(port)
    end
  rescue
    error in ErlangError -> {:error, Map.get(error, :original, :badarg)}
  end

  defp receive_output(port, output, deadline) do
    receive do
      {^port, {:data, data}} ->
        if byte_size(output) + byte_size(data) >= @output_limit,
          do: {:error, :output_limit},
          else: receive_output(port, output <> data, deadline)

      {^port, {:exit_status, status}} ->
        {output, status}
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> {output, :timeout}
    end
  end

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
