# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.DaemonTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  alias Dnsmasqex.Daemon

  test "backs off instead of exiting when the program exits" do
    capture_log(fn ->
      server = start_supervised!({Daemon, ifname: "eth1", command: "sleep", args: ["60"]})
      %{pid: pid, backoff: 1_000} = :sys.get_state(server)
      ref = Process.monitor(pid)

      System.cmd("kill", ["-9", to_string(MuonTrap.Daemon.os_pid(pid))])

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2000
      assert %{pid: nil, backoff: 2_000} = :sys.get_state(server)
      assert Process.alive?(server)
    end)
  end

  test "backs off when the program can't be started" do
    capture_log(fn ->
      server =
        start_supervised!({Daemon, ifname: "eth1", command: "/nonexistent/dnsmasq", args: []})

      assert %{pid: nil, backoff: 2_000} = :sys.get_state(server)
      assert Process.alive?(server)
    end)
  end

  test "stops the program when it stops" do
    fifo = Path.expand("../../test_tmp/daemon.fifo", __DIR__)
    File.mkdir_p!(Path.dirname(fifo))
    File.rm(fifo)
    {_output, 0} = System.cmd("mkfifo", [fifo])

    reader =
      Port.open({:spawn_executable, System.find_executable("cat")}, [
        :binary,
        :exit_status,
        args: [fifo]
      ])

    {:os_pid, reader_pid} = Port.info(reader, :os_pid)
    on_exit(fn -> System.cmd("kill", [to_string(reader_pid)]) end)

    script = "exec 3>#{fifo}; echo ready >&3; exec sleep 60"
    start_supervised!({Daemon, ifname: "eth1", command: "sh", args: ["-c", script]})
    assert_receive {^reader, {:data, "ready\n"}}, 3000

    stop_supervised!(Daemon)

    assert_receive {^reader, {:exit_status, 0}}, 3000
  end
end
