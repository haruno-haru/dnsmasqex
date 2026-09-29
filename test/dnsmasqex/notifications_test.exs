# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.NotificationsTest do
  use ExUnit.Case

  alias Dnsmasqex.Config
  alias Dnsmasqex.Event
  alias Dnsmasqex.Notifications
  alias VintageNet.Interface.RawConfig

  @moduletag :tmp_dir
  @ifname "dnsmasq_test0"

  setup %{tmp_dir: tmp_dir} do
    on_exit(fn ->
      Notifications.clear(@ifname)
      PropertyTable.delete(VintageNet, ["interface", @ifname, "addresses"])
    end)

    %{
      context: %{
        ifname: @ifname,
        subnets: [%{address: {192, 168, 24, 1}, prefix_length: 24}],
        lease_path: Path.join(tmp_dir, "dnsmasq.#{@ifname}.leases")
      }
    }
  end

  test "ignores neighbors on other interfaces' subnets", %{context: context} do
    Notifications.dispatch(["arp-add", "aa:bb:cc:dd:ee:01", "10.0.0.1"], %{}, context)
    assert VintageNet.get(["interface", @ifname, "dnsmasq", "event"]) == nil

    Notifications.dispatch(["arp-add", "aa:bb:cc:dd:ee:02", "192.168.24.20"], %{}, context)

    assert %Event{name: "arp-add", ip: "192.168.24.20"} =
             VintageNet.get(["interface", @ifname, "dnsmasq", "event"])
  end

  test "publishes the updated leases before their event", %{context: context} do
    File.write!(context.lease_path, "0 aa:bb:cc:dd:ee:ff 192.168.24.100 printer *\n")
    VintageNet.subscribe(["interface", @ifname])

    Notifications.dispatch(
      ["add", "aa:bb:cc:dd:ee:ff", "192.168.24.100", "printer"],
      %{},
      context
    )

    assert %Event{name: "add", mac: "aa:bb:cc:dd:ee:ff"} =
             VintageNet.get(["interface", @ifname, "dnsmasq", "event"])

    assert [%{lease_mac: "aa:bb:cc:dd:ee:ff", leasetime: :infinity}] =
             VintageNet.get(["interface", @ifname, "dhcpd", "leases"])

    assert_receive {VintageNet, ["interface", @ifname, first | _], _, _, _}
    assert first == "dhcpd"
    assert_receive {VintageNet, ["interface", @ifname, "dnsmasq", "event"], _, %Event{}, _}
  end

  test "delivers consecutive identical script events without clearing the latest value", %{
    tmp_dir: tmp_dir
  } do
    [_server, notifier, %{start: {_, _, [daemon_args]}}] = raw_config(tmp_dir).child_specs
    start_supervised!(notifier)
    property = ["interface", @ifname, "dnsmasq", "event"]
    VintageNet.subscribe(property)
    env = daemon_args[:opts][:env]
    args = ["tftp", "1024", "192.168.24.10", "/boot/firmware.bin"]

    assert {"", 0} = System.cmd(BEAMNotify.bin_path(), args, env: env)
    assert_receive {VintageNet, ^property, nil, first, _}, 1000
    assert %Event{name: "tftp", file_size: 1024, file_name: "/boot/firmware.bin"} = first
    assert {"", 0} = System.cmd(BEAMNotify.bin_path(), args, env: env)
    assert_receive {VintageNet, ^property, ^first, second, _}, 1000
    assert is_integer(first.id)
    assert second.id != first.id
    assert %{second | id: first.id} == first
    assert VintageNet.get(property) == second
    refute_received {VintageNet, ^property, _, nil, _}
  end

  test "follows live interface prefixes through renumbering and address removal", %{
    context: context
  } do
    property = ["interface", @ifname, "dnsmasq", "event"]
    addresses = ["interface", @ifname, "addresses"]
    first = %{address: {0xFD12, 0, 0, 1, 0, 0, 0, 1}, prefix_length: 64}
    second = %{address: {0xFD12, 0, 0, 2, 0, 0, 0, 1}, prefix_length: 64}

    PropertyTable.put(VintageNet, addresses, [first])
    Notifications.dispatch(["arp-add", "aa:bb:cc:dd:ee:ff", "fd12:0:0:1::10"], %{}, context)
    assert %Event{ip: "fd12:0:0:1::10"} = VintageNet.get(property)

    PropertyTable.put(VintageNet, addresses, [second])
    Notifications.dispatch(["arp-add", "aa:bb:cc:dd:ee:ff", "fd12:0:0:2::10"], %{}, context)
    assert %Event{ip: "fd12:0:0:2::10"} = latest = VintageNet.get(property)

    for ip <- ["fd12:0:0:1::10", "fd12:0:0:3::10", "192.168.24.10", "fe80::10"] do
      Notifications.dispatch(["arp-add", "aa:bb:cc:dd:ee:ff", ip], %{}, context)
      assert VintageNet.get(property) == latest
    end

    PropertyTable.put(VintageNet, addresses, [])

    for ip <- ["fd12:0:0:2::10", "192.168.24.10"] do
      Notifications.dispatch(["arp-add", "aa:bb:cc:dd:ee:ff", ip], %{}, context)
      assert VintageNet.get(property) == latest
    end
  end

  test "configured script reports dnsmasq environment variables", %{
    tmp_dir: tmp_dir,
    context: context
  } do
    raw_config = raw_config(tmp_dir)
    [_server, notifier, %{start: {_, _, [daemon_args]}}] = raw_config.child_specs
    start_supervised!(notifier)
    File.write!(context.lease_path, "")
    property = ["interface", @ifname, "dnsmasq", "event"]
    VintageNet.subscribe(property)

    env =
      daemon_args[:opts][:env]
      |> Map.new()
      |> Map.merge(%{
        "DNSMASQ_SUPPLIED_HOSTNAME" => "printer",
        "DNSMASQ_CLIENT_ID" => "01:aa:bb:cc:dd:ee:ff",
        "DNSMASQ_VENDOR_CLASS" => "test client",
        "DNSMASQ_TAGS" => "eth1 known",
        "DNSMASQ_TIME_REMAINING" => "3600"
      })

    assert {"", 0} =
             System.cmd(
               BEAMNotify.bin_path(),
               ["add", "aa:bb:cc:dd:ee:ff", "192.168.24.10", "printer"],
               env: env
             )

    assert_receive {VintageNet, ^property, nil,
                    %Event{
                      name: "add",
                      supplied_hostname: "printer",
                      client_id: "01:aa:bb:cc:dd:ee:ff",
                      vendor_class: "test client",
                      tags: ["eth1", "known"],
                      time_remaining: 3600
                    }, _meta},
                   1000
  end

  test "daemon uses VintageNet's MuonTrap options", %{tmp_dir: tmp_dir} do
    previous = Application.fetch_env!(:vintage_net, :muontrap_options)
    on_exit(fn -> Application.put_env(:vintage_net, :muontrap_options, previous) end)
    Application.put_env(:vintage_net, :muontrap_options, delay_to_sigkill: 250)

    [_server, _notifier, %{start: {_, _, [daemon_args]}}] = raw_config(tmp_dir).child_specs

    assert daemon_args[:opts][:delay_to_sigkill] == 250
    assert daemon_args[:opts][:env]["BEAM_NOTIFY_OPTIONS"] =~ "-e"
  end

  test "ignores invalid neighbors and unconfigured address families", %{context: context} do
    for ip <- ["invalid", "2001:db8::1", <<255>>] do
      assert :ok = Notifications.dispatch(["arp-add", "aa:bb:cc:dd:ee:ff", ip], %{}, context)
      assert VintageNet.get(["interface", @ifname, "dnsmasq", "event"]) == nil
    end
  end

  test "publishes neighbors on the configured IPv6 subnet only", %{context: context} do
    context = %{
      context
      | subnets: [
          %{address: {0xFD12, 0x3456, 0x789A, 1, 0, 0, 0, 1}, prefix_length: 64} | context.subnets
        ]
    }

    property = ["interface", @ifname, "dnsmasq", "event"]

    for ip <- ["fd12:3456:789a:2::10", "fe80::10", "ff02::1"] do
      Notifications.dispatch(["arp-add", "aa:bb:cc:dd:ee:ff", ip], %{}, context)
      assert VintageNet.get(property) == nil
    end

    Notifications.dispatch(["arp-add", "aa:bb:cc:dd:ee:ff", "fd12:3456:789a:1::10"], %{}, context)
    assert %Event{ip: "fd12:3456:789a:1::10"} = VintageNet.get(property)
  end

  test "publishes DHCPv6 leases and clears them on shutdown", %{context: context} do
    duid = "00:03:00:01:aa:bb:cc:dd:ee:ff"
    File.write!(context.lease_path, "1600 42 fd12:3456:789a:1::10 esp32 #{duid}\n")

    Notifications.dispatch(
      ["add", duid, "fd12:3456:789a:1::10", "esp32"],
      %{"DNSMASQ_IAID" => "42"},
      context
    )

    assert %Event{duid: ^duid, mac: nil} =
             VintageNet.get(["interface", @ifname, "dnsmasq", "event"])

    assert [%{lease_iaid: "42", lease_duid: ^duid, lease_mac: nil}] =
             VintageNet.get(["interface", @ifname, "dhcpd", "leases"])

    Notifications.clear(@ifname)
    assert VintageNet.get(["interface", @ifname, "dhcpd", "leases"]) == nil
  end

  test "excludes scoped IPv6 neighbors even when a broad prefix contains them", %{
    context: context
  } do
    context = %{
      context
      | subnets: [%{address: {0xFD12, 0x3456, 0x789A, 1, 0, 0, 0, 1}, prefix_length: 1}]
    }

    for ip <- ["fe80::10", "febf::10", "ff02::1"] do
      Notifications.dispatch(["arp-add", "aa:bb:cc:dd:ee:ff", ip], %{}, context)
      assert VintageNet.get(["interface", @ifname, "dnsmasq", "event"]) == nil
    end

    Notifications.dispatch(["arp-add", "aa:bb:cc:dd:ee:ff", "fd12:3456:789a:1::10"], %{}, context)

    assert %Event{ip: "fd12:3456:789a:1::10"} =
             VintageNet.get(["interface", @ifname, "dnsmasq", "event"])
  end

  defp raw_config(tmp_dir) do
    config =
      Config.normalize(%{
        ipv4: %{method: :static, address: {192, 168, 24, 1}, prefix_length: 24},
        dnsmasq: %{}
      })

    Config.add_config(
      %RawConfig{
        ifname: @ifname,
        type: Dnsmasqex,
        source_config: config,
        required_ifnames: [@ifname]
      },
      config,
      tmpdir: tmp_dir
    )
  end
end
