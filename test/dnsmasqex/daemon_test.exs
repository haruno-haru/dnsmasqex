# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.DaemonTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  alias Dnsmasqex.Daemon

  test "backs off instead of exiting when the program stops" do
    capture_log(fn ->
      server = start_supervised!({Daemon, ifname: "eth1", command: "sleep", args: ["60"]})
      %{pid: pid, backoff: 1_000} = :sys.get_state(server)
      ref = Process.monitor(pid)

      Process.exit(pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      assert %{pid: nil, backoff: 2_000} = :sys.get_state(server)
      assert Process.alive?(server)
    end)
  end

  test "stops the program when it stops" do
    server = start_supervised!({Daemon, ifname: "eth1", command: "sleep", args: ["60"]})
    %{pid: pid} = :sys.get_state(server)
    ref = Process.monitor(pid)

    stop_supervised!(Daemon)

    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end
end
