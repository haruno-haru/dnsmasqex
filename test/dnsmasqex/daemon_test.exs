# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.DaemonTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  alias Dnsmasqex.Config
  alias Dnsmasqex.Daemon
  alias Dnsmasqex.Server
  alias VintageNet.Interface.RawConfig

  setup do
    on_exit(fn -> Dnsmasqex.Notifications.clear("eth1") end)
  end

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
      assert %{state: :retrying, retry_in: 1_000} = status()

      assert_receive {:ready, next_pid}, 2000
      refute next_pid == pid
      assert %{pid: ^next_pid, backoff: 2_000} = :sys.get_state(server)
    end)
  end

  @tag :tmp_dir
  @tag :dnsmasq
  test "keeps the supervisor alive and reports a permanent configuration failure", %{
    tmp_dir: tmpdir
  } do
    conf = Path.join(tmpdir, "dnsmasq.conf")
    File.write!(conf, "not-a-dnsmasq-option\n")

    capture_log(fn ->
      server =
        start_supervised!(
          {Daemon, ifname: "eth1", command: "dnsmasq", args: [], config_path: conf}
        )

      assert %{pid: nil, backoff: 1_000} = :sys.get_state(server)
      assert Process.alive?(server)
      assert %{state: :failed, reason: {:invalid_configuration, message}} = status()
      assert message =~ "bad option"
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

  test "manual retries do not let an old timer shorten the next backoff" do
    property = ["interface", "eth1", "dnsmasq", "status"]
    VintageNet.subscribe(property)
    owner = self()

    capture_log(fn ->
      start_supervised!(
        {Daemon,
         ifname: "eth1",
         command: "sh",
         args: ["-c", "echo ready; exit 3"],
         opts: [logger_fun: fn "ready" -> send(owner, :ready) end]}
      )

      assert_receive :ready, 2000
      assert_receive {VintageNet, ^property, _, %{state: :retrying, retry_in: 1000}, _}, 2000

      Daemon.retry("eth1")

      assert_receive :ready, 2000
      assert_receive {VintageNet, ^property, _, %{state: :retrying, retry_in: 2000}, _}, 2000
      refute_receive :ready, 1500
      assert_receive :ready, 1500
    end)
  end

  @tag :tmp_dir
  test "validates current native directories and recovers when the server restores its configuration",
       %{tmp_dir: tmpdir} do
    previous = Path.join(tmpdir, "previous")
    current = Path.join(tmpdir, "current")
    File.mkdir!(previous)
    File.mkdir!(current)
    command = Path.join(tmpdir, "dnsmasq")

    File.write!(command, """
    #!/bin/sh
    case "$1" in
      --version)
        echo 'Dnsmasq version 2.93'
        echo 'Compile time options: DHCP inotify'
        ;;
      --test) exit 0 ;;
      *) echo ready; exec sleep 60 ;;
    esac
    """)

    File.chmod!(command, 0o700)
    Application.put_env(:dnsmasqex, :dnsmasq, command)
    on_exit(fn -> Application.delete_env(:dnsmasqex, :dnsmasq) end)

    config =
      Config.normalize(%{
        ipv4: %{method: :static, address: {192, 0, 2, 1}, prefix_length: 24},
        dnsmasq: %{directives: [dhcp_optsdir: previous]}
      })

    raw =
      Config.add_config(
        %RawConfig{
          ifname: "eth1",
          type: Dnsmasqex,
          source_config: config,
          required_ifnames: ["eth1"]
        },
        config,
        tmpdir: tmpdir
      )

    for {path, contents} <- raw.files, do: File.write!(path, contents)
    start_supervised!({Server, ifname: "eth1", tmpdir: tmpdir, config: config})
    owner = self()

    start_supervised!(
      {Daemon,
       ifname: "eth1",
       command: command,
       args: [],
       config_path: Config.conf_path(tmpdir, "eth1"),
       required_features: Config.required_features(config),
       runtime_files: Config.validation_files(config, tmpdir, "eth1"),
       opts: [logger_fun: fn "ready" -> send(owner, {:ready, self()}) end]}
    )

    assert_receive {:ready, pid}, 2000
    assert :ok = Server.update("eth1", :directives, [[dhcp_optsdir: current]])
    :ok = File.rmdir(previous)
    Process.exit(pid, :kill)

    assert_receive {:ready, next_pid}, 2000
    refute next_pid == pid

    property = ["interface", "eth1", "dnsmasq", "status"]
    VintageNet.subscribe(property)
    File.rmdir!(current)
    Process.exit(next_pid, :kill)
    assert_receive {VintageNet, ^property, _, %{state: :failed}, _}, 5000

    File.mkdir!(previous)
    stop_supervised!(Server)
    start_supervised!({Server, ifname: "eth1", tmpdir: tmpdir, config: config})
    assert_receive {:ready, restored_pid}, 2000
    refute restored_pid == next_pid
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
    assert %{state: :stopped} = status()
  end

  defp status(), do: VintageNet.get(["interface", "eth1", "dnsmasq", "status"])

  test "keeps the real exit status for a failed system daemon" do
    property = ["interface", "eth1", "dnsmasq", "status"]
    VintageNet.subscribe(property)

    capture_log(fn ->
      start_supervised!({Daemon, ifname: "eth1", command: "sh", args: ["-c", "exit 3"]})

      assert_receive {VintageNet, ^property, _, %{state: :retrying, reason: {:exit_status, 3}},
                      _},
                     2000
    end)
  end

  @tag :tmp_dir
  test "terminates a process that never becomes ready and reports the timeout", %{tmp_dir: tmpdir} do
    property = ["interface", "eth1", "dnsmasq", "status"]
    VintageNet.subscribe(property)

    capture_log(fn ->
      server =
        start_supervised!(
          {Daemon,
           ifname: "eth1",
           command: "sleep",
           args: ["60"],
           pid_path: Path.join(tmpdir, "missing.pid"),
           startup_timeout: 50}
        )

      %{pid: pid} = :sys.get_state(server)
      ref = Process.monitor(pid)

      assert_receive {VintageNet, ^property, _, %{state: :retrying, reason: :startup_timeout}, _},
                     2000

      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 2000
      assert Process.alive?(server)
    end)
  end
end
