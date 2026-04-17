# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.DaemonTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  alias Dnsmasqex.Daemon

  test "backs off instead of exiting when the daemon exits" do
    capture_log(fn ->
      owner = self()

      server =
        start_supervised!(
          {Daemon,
           ifname: "eth1",
           command: "sh",
           args: ["-c", "echo ready; exec sleep 60"],
           opts: [logger_fun: fn "ready" -> send(owner, {:ready, self()}) end]}
        )

      %{pid: pid, backoff: 1_000} = :sys.get_state(server)
      ref = Process.monitor(pid)
      assert_receive {:ready, ^pid}, 1000

      Process.exit(pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2000
      assert %{pid: nil, backoff: 2_000} = :sys.get_state(server)
      assert Process.alive?(server)

      assert_receive {:ready, next_pid}, 2000
      refute next_pid == pid
      assert %{pid: ^next_pid, backoff: 2_000} = :sys.get_state(server)
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

  @tag :tmp_dir
  test "stops the program when it stops", %{tmp_dir: tmp_dir} do
    fifo = Path.join(tmp_dir, "daemon.fifo")
    {_output, 0} = System.cmd("mkfifo", [fifo])
    owner = self()

    reader =
      start_supervised!(
        {MuonTrap.Daemon, ["cat", [fifo], [logger_fun: fn "ready" -> send(owner, :ready) end]]},
        restart: :temporary
      )

    ref = Process.monitor(reader)

    script = "exec 3>\"$1\"; echo ready >&3; exec sleep 60"
    start_supervised!({Daemon, ifname: "eth1", command: "sh", args: ["-c", script, "sh", fifo]})
    assert_receive :ready, 3000

    stop_supervised!(Daemon)

    assert_receive {:DOWN, ^ref, :process, ^reader, :normal}, 3000
  end

  test "stops its linked daemon on a normal exit" do
    {:ok, server} = Daemon.start_link(ifname: "eth1", command: "sleep", args: ["60"])
    %{pid: pid} = :sys.get_state(server)
    ref = Process.monitor(pid)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    GenServer.stop(server)

    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}
  end
end
