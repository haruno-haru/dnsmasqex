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

  defp start_server(context, mode, extra \\ %{}) do
    range =
      if mode in [:stateful, :slaac],
        do: %{start: "fd12:3456:789a:1::100", end: "fd12:3456:789a:1::110"},
        else: %{}

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
              name_servers: [],
              options: %{dns: ["192.0.2.1"]},
              options6: %{dns: ["fd12:3456:789a:1::1"], search: ["lan"]},
              dhcpv6: Map.merge(range, %{mode: mode, lease_time: 600})
            },
            extra
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
        tmpdir: context.tmp_dir
      )

    Enum.each(raw.files, fn {path, contents} -> File.write!(path, contents) end)
    Enum.each(raw.up_cmds, &run_command/1)

    eventually(fn ->
      {output, 0} = System.cmd("ip", ["-6", "addr", "show", "dev", @ifname, "tentative"])
      output == ""
    end)

    Enum.each(raw.child_specs, &start_supervised!/1)

    eventually(fn ->
      match?(%{state: :running}, VintageNet.get(["interface", @ifname, "dnsmasq", "status"]))
    end)
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
