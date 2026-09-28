# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.DNSIntegrationTest do
  use ExUnit.Case, async: true

  alias Dnsmasqex.Config
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

  defp start_dnsmasq(tmpdir) do
    ifname = if :os.type() == {:unix, :linux}, do: "lo", else: "lo0"

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
    :ok = :gen_tcp.close(socket)

    args = [
      "--keep-in-foreground",
      "--user=#{System.get_env("USER", "root")}",
      "--log-facility=-",
      "--port=#{port}",
      "-C",
      Config.conf_path(tmpdir, ifname)
    ]

    start_supervised!({MuonTrap.Daemon, ["dnsmasq", args, [stderr_to_stdout: true]]})

    %{port: port, ifname: ifname, config: config}
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
