# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.DNSIntegrationTest do
  use ExUnit.Case, async: true

  alias Dnsmasqex.Config
  alias Dnsmasqex.Daemon
  alias Dnsmasqex.Notifications
  alias Dnsmasqex.Server
  alias VintageNet.Interface.RawConfig

  @moduletag :dnsmasq
  @moduletag :tmp_dir
  @loopback {0, 0, 0, 0, 0, 0, 0, 1}
  @address {0xFD12, 0x3456, 0x789A, 1, 0, 0, 0, 0x100}

  test "answers AAAA and A queries over IPv6 UDP and TCP", %{tmp_dir: tmpdir} do
    %{port: port} = start_dnsmasq(tmpdir)

    assert eventually_resolve("esp32.lan", :aaaa, port, 30) == [@address]

    for tcp? <- [false, true] do
      assert resolve("esp32.lan", :aaaa, port, tcp?) == [@address]
      assert resolve("esp32.lan", :a, port, tcp?) == [{192, 168, 24, 100}]
      assert resolve("device.apps.lan", :aaaa, port, tcp?) == [@address]

      assert :inet_res.lookup(
               ~c"esp32.lan",
               :in,
               :a,
               [nameservers: [{{127, 0, 0, 1}, port}], timeout: 100, retry: 1, usevc: tcp?],
               200
             ) == []
    end
  end

  @tag :linux
  test "reloads AAAA records in the running daemon", %{tmp_dir: tmpdir} do
    %{port: port, ifname: ifname, config: config} = start_dnsmasq(tmpdir)
    on_exit(fn -> Notifications.clear(ifname) end)
    start_supervised!({Server, ifname: ifname, tmpdir: tmpdir, config: config})

    assert eventually_resolve("esp32.lan", :aaaa, port, 30) == [@address]
    assert :ok = Server.update(ifname, :put_record, [{"esp32.lan", "fd12:3456:789a:1::101"}])

    # A new name makes the wait independent of the old answer and resolver caching.
    assert :ok = Server.update(ifname, :add_record, [{"printer.lan", "fd12:3456:789a:1::101"}])
    address = {0xFD12, 0x3456, 0x789A, 1, 0, 0, 0, 0x101}
    assert eventually_resolve("printer.lan", :aaaa, port, 30) == [address]
    assert resolve("esp32.lan", :aaaa, port) == [address]
  end

  @tag :linux
  test "reports a port conflict and becomes ready after the port is released", %{tmp_dir: tmpdir} do
    property = ["interface", "lo", "dnsmasq", "status"]
    VintageNet.subscribe(property)
    %{port: port, socket: socket} = start_dnsmasq(tmpdir, true)
    assert_receive {VintageNet, ^property, _, %{state: :retrying}, _}, 3000
    :ok = :gen_tcp.close(socket)
    assert_receive {VintageNet, ^property, _, %{state: :running, pid: pid}, _}, 5000
    assert pid > 0
    assert resolve("esp32.lan", :aaaa, port) == [@address]
    stop_supervised!(Daemon)
    assert VintageNet.get(property) == %{state: :stopped}
  end

  defp start_dnsmasq(tmpdir, block_port? \\ false) do
    ifname = if :os.type() == {:unix, :linux}, do: "lo", else: "lo0"
    on_exit(fn -> Notifications.clear(ifname) end)

    config =
      Config.normalize(%{
        ipv6: %{method: :static, address: "fd12:3456:789a:1::1", prefix_length: 64},
        dnsmasq: %{
          name_servers: [],
          records: [{"esp32.lan", @address}, {"esp32.lan", "192.168.24.100"}],
          domain_records: [{"apps.lan", "fd12:3456:789a:1::100"}]
        }
      })

    raw =
      Config.add_config(
        %RawConfig{
          ifname: ifname,
          type: Dnsmasqex,
          source_config: config,
          required_ifnames: [ifname]
        },
        config,
        tmpdir: tmpdir
      )

    # Use loopback and an unprivileged port; do not reconfigure a real interface.
    Enum.each(raw.files, fn {path, contents} ->
      contents =
        contents
        |> String.replace("except-interface=lo\n", "")
        |> String.replace("listen-address=fd12:3456:789a:1::1", "listen-address=::1")

      File.write!(path, contents)
    end)

    {:ok, socket} = :gen_tcp.listen(0, [:inet6, ip: @loopback])
    {:ok, port} = :inet.port(socket)
    if block_port?, do: on_exit(fn -> :gen_tcp.close(socket) end), else: :gen_tcp.close(socket)

    args = [
      "--keep-in-foreground",
      "--user=#{System.get_env("USER", "root")}",
      "--log-facility=-",
      "--port=#{port}",
      "-C",
      Config.conf_path(tmpdir, ifname)
    ]

    start_supervised!(
      {Daemon,
       ifname: ifname,
       command: "dnsmasq",
       args: args,
       config_path: Config.conf_path(tmpdir, ifname),
       pid_path: Config.pid_path(tmpdir, ifname),
       required_features: Config.required_features(config),
       runtime_files:
         Enum.map(Config.runtime_options(), &{&1, Config.runtime_path(&1, tmpdir, ifname)}),
       opts: [stderr_to_stdout: true, log_output: :debug]}
    )

    %{port: port, ifname: ifname, config: config, socket: socket}
  end

  defp eventually_resolve(name, type, port, attempts) do
    case resolve(name, type, port) do
      [] when attempts > 0 ->
        Process.sleep(50)
        eventually_resolve(name, type, port, attempts - 1)

      result ->
        result
    end
  end

  defp resolve(name, type, port, tcp? \\ false),
    do:
      :inet_res.lookup(
        String.to_charlist(name),
        :in,
        type,
        [nameservers: [{@loopback, port}], timeout: 100, retry: 1, usevc: tcp?],
        200
      )
end
