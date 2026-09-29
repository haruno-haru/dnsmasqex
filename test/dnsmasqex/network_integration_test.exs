# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.NetworkIntegrationTest do
  use ExUnit.Case

  alias Dnsmasqex.Config
  alias Dnsmasqex.Event
  alias Dnsmasqex.Notifications
  alias Dnsmasqex.Server
  alias Dnsmasqex.Test.DNSStub
  alias VintageNet.Interface.RawConfig

  @moduletag :network
  @moduletag :tmp_dir
  @moduletag timeout: 60_000
  @ifname "dnssrv0"
  @client "dnscli0"
  @duid "00:03:00:01:02:00:00:00:00:02"

  setup do
    # The whole BEAM must run inside `unshare --net`; never change host links.
    assert {:unix, :linux} == :os.type()
    assert {"0\n", 0} == System.cmd("id", ["-u"])
    assert File.read_link!("/proc/self/ns/net") != File.read_link!("/proc/1/ns/net")
    namespace = "dnsmasqex-#{System.unique_integer([:positive])}"
    ip(["netns", "add", namespace])

    on_exit(fn ->
      System.cmd("ip", ["netns", "del", namespace], stderr_to_stdout: true)
      System.cmd("ip", ["link", "del", @ifname], stderr_to_stdout: true)
      Notifications.clear(@ifname)
    end)

    ip(["link", "set", "lo", "up"])
    ip(["link", "add", @ifname, "type", "veth", "peer", "name", @client])
    ip(["link", "set", @client, "netns", namespace])

    for {prefix, device, mac, address} <- [
          {[], @ifname, "02:00:00:00:00:01", "fe80::1/64"},
          {["-n", namespace], @client, "02:00:00:00:00:02", "fe80::2/64"}
        ] do
      ip(prefix ++ ["link", "set", device, "address", mac, "addrgenmode", "none"])
      ip(prefix ++ ["link", "set", device, "up"])
      ip(prefix ++ ["-6", "addr", "add", address, "dev", device, "nodad"])
    end

    ip(["-n", namespace, "addr", "add", "192.0.2.2/24", "dev", @client])
    %{namespace: namespace}
  end

  test "allocates, renews, rebinds and releases both families with live option updates",
       context do
    start_server(context, :stateful)
    property = ["interface", @ifname, "dnsmasq", "event"]
    VintageNet.subscribe(property)

    [address4, address6] =
      context |> client(["acquire", state_path(context), "192.0.2.1"]) |> String.split()

    ip(["-n", context.namespace, "addr", "add", "#{address4}/24", "dev", @client])

    eventually(fn -> length(leases()) == 2 end)
    assert Enum.any?(leases(), &match?(%{lease_nip: ^address4, hostname: "esp32"}, &1))

    assert Enum.any?(
             leases(),
             &match?(%{lease_nip: ^address6, lease_duid: @duid, lease_iaid: "42"}, &1)
           )

    assert_receive {VintageNet, ^property, _,
                    %Event{name: "add", duid: @duid, iaid: "42", server_duid: server_duid}, _},
                   3000

    assert is_binary(server_duid) and server_duid != ""
    {:ok, ip4} = VintageNet.IP.ip_to_tuple(address4)
    {:ok, ip6} = VintageNet.IP.ip_to_tuple(address6)
    assert elem(ip4, 3) in 100..110
    assert elem(ip6, 7) in 0x100..0x110
    assert resolve("esp32.lan", :a) == [ip4]
    assert resolve("esp32v6.lan", :aaaa) == [ip6]

    # The parser accepts this file, but only a new ACK proves SIGHUP loaded it.
    assert :ok = Server.update(@ifname, :put_option, [:dns, ["192.0.2.53"]])
    assert :ok = Server.update(@ifname, :put_option6, [23, "[fd12:3456:789a:1::53]"])

    assert client(context, ["renew", state_path(context), "192.0.2.53", "fd12:3456:789a:1::53"]) ==
             "#{address4} #{address6}\n"

    assert client(context, ["release", state_path(context), "192.0.2.53"]) == ""
    eventually(fn -> leases() == [] end)
    assert resolve("esp32.lan", :a) == []
    assert resolve("esp32v6.lan", :aaaa) == []
  end

  test "uses MAC and DUID reservations and reloads both when they change", context do
    lease4 = %{mac: "02:00:00:00:00:02", ip: "192.0.2.120", lease_time: 600}
    lease6 = %{duid: @duid, ip: "fd12:3456:789a:1::120", lease_time: 600}
    start_server(context, :stateful, %{static_leases: [lease4], static_leases6: [lease6]})

    assert client(context, ["acquire", state_path(context), "192.0.2.1"]) ==
             "192.0.2.120 fd12:3456:789a:1::120\n"

    ip(["-n", context.namespace, "addr", "add", "192.0.2.120/24", "dev", @client])
    assert client(context, ["release", state_path(context), "192.0.2.1"]) == ""
    eventually(fn -> leases() == [] end)

    assert :ok = Server.update(@ifname, :put_static_lease, [%{lease4 | ip: "192.0.2.121"}])

    assert :ok =
             Server.update(@ifname, :put_static_lease6, [%{lease6 | ip: "fd12:3456:789a:1::121"}])

    assert client(context, ["acquire", state_path(context), "192.0.2.1"]) ==
             "192.0.2.121 fd12:3456:789a:1::121\n"
  end

  for mode <- [:stateful, :slaac, :stateless, :ra_only] do
    @mode mode
    test "advertises the correct flags, prefix, DNS and route lifetime for #{mode}", context do
      start_server(context, @mode, %{enable_ra: true, ra_lifetime: 0})
      assert client(context, ["ra", Atom.to_string(@mode)]) == ""
    end
  end

  test "forwards queries to a scoped link-local IPv6 upstream", context do
    start_server(context, :stateful, %{name_servers: ["fe80::2%#{@ifname}"]})
    assert client(context, ["upstream"]) == ""
  end

  test "uses VintageNet's custom resolver file for real forwarding", context do
    path = Path.join(context.tmp_dir, "custom-resolv.conf")
    File.write!(path, "nameserver 192.0.2.2\n")
    start_server(Map.put(context, :resolvconf, path), :stateful, %{name_servers: :system})
    assert client(context, ["resolver-upstream"]) == ""
  end

  test "preserves leases and server DUID through a supervised restart", context do
    %{supervisor: supervisor} =
      start_server(context, :stateful, %{
        lease_path: Path.join(context.tmp_dir, "persistent.leases")
      })

    [address4, address6] =
      context |> client(["acquire", state_path(context), "192.0.2.1"]) |> String.split()

    ip(["-n", context.namespace, "addr", "add", "#{address4}/24", "dev", @client])
    eventually(fn -> length(leases()) == 2 end)
    assert :ok = Supervisor.terminate_child(supervisor, :dnsmasq)
    assert {:ok, _} = Supervisor.restart_child(supervisor, :dnsmasq)

    eventually(fn ->
      match?(%{state: :running}, VintageNet.get(["interface", @ifname, "dnsmasq", "status"]))
    end)

    assert client(context, ["renew", state_path(context), "192.0.2.1"]) ==
             "#{address4} #{address6}\n"

    assert length(leases()) == 2
  end

  test "serves static DHCPv6 reservations without a dynamic IPv6 pool", context do
    start_server(context, :static, %{
      static_leases6: [
        %{duid: @duid, ip: "fd12:3456:789a:1::120", lease_time: 600}
      ]
    })

    assert client(context, ["acquire", state_path(context), "192.0.2.1"]) =~
             " fd12:3456:789a:1::120\n"
  end

  test "handles DHCPv6 Rapid Commit, Confirm, Decline and temporary addresses", context do
    start_server(context, :stateful)
    assert client(context, ["advanced6"]) == ""
  end

  test "applies client-ID reservations and tagged forced options", context do
    start_server(context, :stateful, %{
      directives: [dhcp_vendorclass: "set:esp,ESP", dhcp_option_force: "tag:esp,42,192.0.2.123"],
      dhcp_hosts: ["id:01:02:00:00:00:00:02,192.0.2.105,esp32,600"]
    })

    assert client(context, ["policy4"]) == ""
    eventually(fn -> Enum.any?(leases(), &(&1[:lease_client_id] == "01:02:00:00:00:00:02")) end)
  end

  test "does not immediately reuse a declined IPv4 address", context do
    start_server(context, :stateful)
    assert client(context, ["decline4"]) == ""
  end

  test "serves a boot file using the system TFTP server", context do
    File.write!(Path.join(context.tmp_dir, "boot.img"), "esp boot image")

    start_server(context, :stateful, %{
      directives: [enable_tftp: true, tftp_root: context.tmp_dir, dhcp_boot: "boot.img"]
    })

    assert client(context, ["tftp", "boot.img", "esp boot image"]) == ""
  end

  test "writes real A and AAAA answers into the selected nftables sets", context do
    rules = Path.join(context.tmp_dir, "sets.nft")

    File.write!(
      rules,
      "table inet dnsmasqex_test {\nset resolved4 { type ipv4_addr; }\nset resolved6 { type ipv6_addr; }\n}\n"
    )

    assert {output, 0} = System.cmd("nft", ["-f", rules], stderr_to_stdout: true)
    assert output == ""

    on_exit(fn ->
      System.cmd("nft", ["delete", "table", "inet", "dnsmasqex_test"], stderr_to_stdout: true)
    end)

    upstream = start_supervised!({DNSStub, owner: self()})
    port = DNSStub.port(upstream)

    start_server(context, :stateful, %{
      name_servers: ["127.0.0.1##{port}"],
      nftsets: [
        {["fw.example"], ["4#inet#dnsmasqex_test#resolved4", "6#inet#dnsmasqex_test#resolved6"]}
      ]
    })

    for tcp? <- [false, true], type <- [:a, :aaaa] do
      name = if tcp?, do: ~c"tcp.fw.example", else: ~c"udp.fw.example"

      assert :inet_res.lookup(
               name,
               :in,
               type,
               [nameservers: [{{192, 0, 2, 1}, 53}], usevc: tcp?, timeout: 500],
               1000
             ) != []
    end

    for {set, address} <- [{"resolved4", "203.0.113.9"}, {"resolved6", "2001:db8::9"}] do
      assert {contents, 0} =
               System.cmd("nft", ["list", "set", "inet", "dnsmasqex_test", set],
                 stderr_to_stdout: true
               )

      assert contents =~ address
    end
  end

  defp start_server(context, mode, extra \\ %{}) do
    range =
      if mode in [:stateful, :slaac],
        do: %{start: "fd12:3456:789a:1::100", end: "fd12:3456:789a:1::110"},
        else: %{}

    extra = if extra[:name_servers] == :system, do: Map.delete(extra, :name_servers), else: extra
    defaults = %{name_servers: []}

    defaults =
      if Map.has_key?(context, :resolvconf),
        do: Map.delete(defaults, :name_servers),
        else: defaults

    config =
      Config.normalize(%{
        ipv4: %{method: :static, address: {192, 0, 2, 1}, prefix_length: 24},
        ipv6: %{method: :static, address: "fd12:3456:789a:1::1", prefix_length: 64},
        dnsmasq:
          Map.merge(
            %{
              start: "192.0.2.100",
              end: "192.0.2.110",
              lease_time: 600,
              domain: "lan",
              authoritative: true,
              options: %{dns: ["192.0.2.1"]},
              options6: %{dns: ["fd12:3456:789a:1::1"], search: ["lan"]},
              dhcpv6: Map.merge(range, %{mode: mode, lease_time: 600})
            },
            Map.merge(defaults, extra)
          )
      })

    raw =
      Config.add_config(
        %RawConfig{
          ifname: @ifname,
          type: Dnsmasqex,
          source_config: config,
          required_ifnames: [@ifname],
          up_cmds: [{:run, "ip", ["addr", "add", "192.0.2.1/24", "dev", @ifname]}]
        },
        config,
        tmpdir: context.tmp_dir,
        resolvconf: Map.get(context, :resolvconf, "/etc/resolv.conf")
      )

    Enum.each(raw.files, fn {path, contents} -> File.write!(path, contents) end)
    Enum.each(raw.up_cmds, &run_command/1)

    eventually(fn ->
      {output, 0} = System.cmd("ip", ["-6", "addr", "show", "dev", @ifname, "tentative"])
      output == ""
    end)

    supervisor =
      start_supervised!(%{
        id: :interface,
        start: {Supervisor, :start_link, [raw.child_specs, [strategy: :one_for_one]]}
      })

    eventually(fn ->
      match?(%{state: :running}, VintageNet.get(["interface", @ifname, "dnsmasq", "status"]))
    end)

    %{supervisor: supervisor, config: config, raw: raw}
  end

  defp run_command({:run, command, args}) do
    assert {output, 0} = System.cmd(command, args, stderr_to_stdout: true)
    output
  end

  defp run_command({:fun, module, function, args}), do: apply(module, function, args)

  defp ip(args), do: run_command({:run, "ip", args})
  defp state_path(context), do: Path.join(context.tmp_dir, "client.json")
  defp leases(), do: VintageNet.get(["interface", @ifname, "dhcpd", "leases"], [])

  defp client(context, args) do
    {output, status} =
      System.cmd(
        "ip",
        [
          "netns",
          "exec",
          context.namespace,
          "python3",
          Path.expand("../support/network_client.py", __DIR__) | args
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    output
  end

  defp resolve(name, type),
    do:
      :inet_res.lookup(
        String.to_charlist(name),
        :in,
        type,
        [nameservers: [{{192, 0, 2, 1}, 53}], timeout: 500, retry: 1],
        1000
      )

  defp eventually(condition, attempts \\ 100) do
    cond do
      condition.() ->
        :ok

      attempts > 0 ->
        Process.sleep(50)
        eventually(condition, attempts - 1)

      true ->
        flunk(
          "condition not met; daemon status: #{inspect(VintageNet.get(["interface", @ifname, "dnsmasq", "status"]))}"
        )
    end
  end
end
