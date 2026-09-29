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
  alias Dnsmasqex.Test.DNSStub
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

  test "serves structured and native records with their actual wire values", %{tmp_dir: tmpdir} do
    %{port: port} =
      start_dnsmasq(tmpdir, false, %{
        cnames: [{"alias.lan", "esp32.lan"}],
        srv_records: [{"_mqtt._tcp.lan", "esp32.lan", 8883, 10, 20}],
        txt_records: [{"esp32.lan", ["model=esp32", "note=\"wired\", value"]}],
        mx_records: [{"lan", "esp32.lan", 10}],
        directives: [
          ptr_record: "99.2.0.192.in-addr.arpa,gateway.lan",
          host_record: "sensor.lan,192.0.2.44,75",
          caa_record: "lan,0,issue,ca.example",
          naptr_record: "lan,10,20,\"s\",\"SIP+D2U\",\"\",_sip._udp.lan",
          dns_rr: "raw.lan,65280,00010203"
        ]
      })

    assert eventually_resolve("esp32.lan", :a, port, 30) == [{192, 168, 24, 100}]

    for tcp? <- [false, true] do
      assert resolve("alias.lan", :a, port, tcp?) == [{192, 168, 24, 100}]
      assert resolve("_mqtt._tcp.lan", :srv, port, tcp?) == [{10, 20, 8883, ~c"esp32.lan"}]

      assert resolve("esp32.lan", :txt, port, tcp?) == [
               [~c"model=esp32", ~c"note=\"wired\", value"]
             ]

      assert resolve("lan", :mx, port, tcp?) == [{10, ~c"esp32.lan"}]
      assert resolve("99.2.0.192.in-addr.arpa", :ptr, port, tcp?) == [~c"gateway.lan"]
      assert resolve("100.24.168.192.in-addr.arpa", :ptr, port, tcp?) == [~c"esp32.lan"]

      assert resolve("lan", :naptr, port, tcp?) == [
               {10, 20, ~c"s", ~c"sip+d2u", ~c"", ~c"_sip._udp.lan"}
             ]

      assert resolve("raw.lan", 65280, port, tcp?) == [<<0, 1, 2, 3>>]
    end

    assert {:ok, response} =
             :inet_res.resolve(
               ~c"sensor.lan",
               :in,
               :a,
               [nameservers: [{@loopback, port}], timeout: 200],
               500
             )

    assert [answer] = :inet_dns.msg(response, :anlist)
    assert :inet_dns.rr(answer, :ttl) == 75
  end

  test "forwards to a custom upstream port and exposes changing cache counters", %{
    tmp_dir: tmpdir
  } do
    upstream = start_supervised!({DNSStub, owner: self()})
    upstream_port = DNSStub.port(upstream)

    %{port: port} =
      start_dnsmasq(tmpdir, false, %{cache_size: 32, name_servers: ["127.0.0.1##{upstream_port}"]})

    assert eventually_resolve("esp32.lan", :a, port, 30) == [{192, 168, 24, 100}]
    assert {:ok, before} = Dnsmasqex.Statistics.query({@loopback, port})
    assert before.cachesize == 32
    assert resolve("cached.example", :a, port) == [{203, 0, 113, 9}]
    assert_receive {:upstream_query, :udp, _, :a}
    assert resolve("cached.example", :a, port) == [{203, 0, 113, 9}]
    refute_receive {:upstream_query, _, _, _}, 100
    assert {:ok, after_query} = Dnsmasqex.Statistics.query({@loopback, port})
    assert after_query.hits > before.hits
    assert after_query.insertions > before.insertions
    assert after_query.servers != []
  end

  test "a truncated upstream UDP response can be retried over TCP", %{tmp_dir: tmpdir} do
    upstream = start_supervised!({DNSStub, owner: self(), truncate_udp: true})
    upstream_port = DNSStub.port(upstream)
    %{port: port} = start_dnsmasq(tmpdir, false, %{name_servers: ["127.0.0.1##{upstream_port}"]})
    assert eventually_resolve("esp32.lan", :a, port, 30) == [{192, 168, 24, 100}]
    query = <<123, 46, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 5, "large", 7, "example", 0, 0, 1, 0, 1>>
    {:ok, socket} = :gen_udp.open(0, [:binary, :inet6, active: false])
    on_exit(fn -> :gen_udp.close(socket) end)
    :ok = :gen_udp.send(socket, @loopback, port, query)
    assert {:ok, {_, ^port, <<123, 46, flags::16, _::binary>>}} = :gen_udp.recv(socket, 0, 2000)
    assert Bitwise.band(flags, 0x0200) != 0
    assert resolve("large.example", :a, port, true) == [{203, 0, 113, 9}]
    assert_receive {:upstream_query, :udp, _, :a}
    assert_receive {:upstream_query, :tcp, _, :a}
  end

  @tag :linux
  test "updates upstreams without restarting and rejects bad native updates atomically", %{
    tmp_dir: tmpdir
  } do
    first = start_supervised!({DNSStub, owner: self()}, id: :first)

    second =
      start_supervised!({DNSStub, owner: self(), address: {203, 0, 113, 10}},
        id: :second
      )

    port1 = DNSStub.port(first)
    port2 = DNSStub.port(second)

    %{port: port, ifname: ifname, config: config} =
      start_dnsmasq(tmpdir, false, %{
        upstreams: [server: "127.0.0.1##{port1}"],
        directives: [txt_record: "configured.lan,original"]
      })

    start_supervised!({Server, ifname: ifname, tmpdir: tmpdir, config: config})
    assert eventually_resolve("first.example", :a, port, 30) == [{203, 0, 113, 9}]
    assert :ok = Server.update(ifname, :upstreams, [[server: "127.0.0.1##{port2}"]])
    assert eventually_resolve("second.example", :a, port, 30) == [{203, 0, 113, 10}]

    assert %{state: :reload_signaled, saved: true} =
             VintageNet.get(["interface", ifname, "dnsmasq", "update"])

    native = Config.runtime_path(:directives, tmpdir, ifname)
    old = File.read!(native)

    assert {:error, {:invalid_configuration, _}} =
             Server.update(ifname, :directives, [[dns_rr: "invalid.lan,65280,nothex"]])

    assert File.read!(native) == old
    assert resolve("second.example", :a, port) == [{203, 0, 113, 10}]

    assert :ok = Server.update(ifname, :directives, [[txt_record: "new.lan,\"after restart\""]])
    assert eventually_resolve("new.lan", :txt, port, 100) == [[~c"after restart"]]
    assert :ok = Server.dump_stats(ifname)

    stop_supervised!(Server)
    start_supervised!({Server, ifname: ifname, tmpdir: tmpdir, config: config})
    assert eventually_resolve("configured.lan", :txt, port, 100) == [[~c"original"]]
    assert resolve("new.lan", :txt, port) == []
    assert resolve("restored.example", :a, port) == [{203, 0, 113, 9}]
  end

  test "serves an authoritative zone with the configured SOA", %{tmp_dir: tmpdir} do
    %{port: port} =
      start_dnsmasq(tmpdir, false, %{
        directives: [
          auth_server: "ns.example",
          auth_zone: "example",
          auth_soa: "2026092901,hostmaster.example,1200,180,1209600",
          host_record: "ns.example,192.0.2.1"
        ]
      })

    assert eventually_resolve("example", :soa, port, 30) ==
             [{~c"ns.example", ~c"hostmaster.example", 2_026_092_901, 1200, 180, 1_209_600, 600}]
  end

  defp start_dnsmasq(tmpdir, block_port? \\ false, extra \\ %{}) do
    ifname = if :os.type() == {:unix, :linux}, do: "lo", else: "lo0"
    on_exit(fn -> Notifications.clear(ifname) end)

    {:ok, socket} = :gen_tcp.listen(0, [:inet6, ip: @loopback])
    {:ok, port} = :inet.port(socket)
    if block_port?, do: on_exit(fn -> :gen_tcp.close(socket) end), else: :gen_tcp.close(socket)

    config =
      Config.normalize(%{
        ipv6: %{method: :static, address: "fd12:3456:789a:1::1", prefix_length: 64},
        dnsmasq:
          Map.merge(
            %{
              port: port,
              name_servers: [],
              records: [{"esp32.lan", @address}, {"esp32.lan", "192.168.24.100"}],
              domain_records: [{"apps.lan", "fd12:3456:789a:1::100"}]
            },
            extra
          )
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

    args = [
      "--keep-in-foreground",
      "--user=#{System.get_env("USER", "root")}",
      "--log-facility=-",
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
        [nameservers: [{@loopback, port}], timeout: 1000, retry: 1, usevc: tcp?],
        2000
      )
end
