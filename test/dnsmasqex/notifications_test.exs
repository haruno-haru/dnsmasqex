# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.NotificationsTest do
  use ExUnit.Case

  alias VintageNet.Interface.RawConfig
  alias Dnsmasqex.Config
  alias Dnsmasqex.Event
  alias Dnsmasqex.Notifications

  @moduletag :tmp_dir
  @ifname "dnsmasq_test0"

  setup %{tmp_dir: tmp_dir} do
    on_exit(fn -> Notifications.clear(@ifname) end)

    %{
      context: %{
        ifname: @ifname,
        address: {192, 168, 24, 1},
        prefix_length: 24,
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

  test "lease events publish the event and the leases", %{context: context} do
    File.write!(context.lease_path, "0 aa:bb:cc:dd:ee:ff 192.168.24.100 printer *\n")

    Notifications.dispatch(
      ["add", "aa:bb:cc:dd:ee:ff", "192.168.24.100", "printer"],
      %{},
      context
    )

    assert %Event{name: "add", mac: "aa:bb:cc:dd:ee:ff"} =
             VintageNet.get(["interface", @ifname, "dnsmasq", "event"])

    assert [%{lease_mac: "aa:bb:cc:dd:ee:ff", leasetime: :infinity}] =
             VintageNet.get(["interface", @ifname, "dhcpd", "leases"])
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

  test "ignores invalid and IPv6 neighbors", %{context: context} do
    for ip <- ["invalid", "2001:db8::1"] do
      assert :ok = Notifications.dispatch(["arp-add", "aa:bb:cc:dd:ee:ff", ip], %{}, context)
      assert VintageNet.get(["interface", @ifname, "dnsmasq", "event"]) == nil
    end
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
