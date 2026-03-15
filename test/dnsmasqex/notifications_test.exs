# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.NotificationsTest do
  use ExUnit.Case

  alias Dnsmasqex.Event
  alias Dnsmasqex.Notifications

  doctest Event

  @ifname "dnsmasq_test0"
  @lease_path Path.expand("../../test_tmp/dnsmasq.leases", __DIR__)
  @context %{
    ifname: @ifname,
    address: {192, 168, 24, 1},
    prefix_length: 24,
    lease_path: @lease_path
  }

  setup do
    File.mkdir_p!(Path.dirname(@lease_path))
    on_exit(fn -> Notifications.clear(@ifname) end)
  end

  test "ignores neighbors on other interfaces' subnets" do
    Notifications.dispatch(["arp-add", "aa:bb:cc:dd:ee:01", "10.0.0.1"], %{}, @context)
    assert VintageNet.get(["interface", @ifname, "dnsmasq", "event"]) == nil

    Notifications.dispatch(["arp-add", "aa:bb:cc:dd:ee:02", "192.168.24.20"], %{}, @context)

    assert %Event{name: "arp-add", ip: "192.168.24.20"} =
             VintageNet.get(["interface", @ifname, "dnsmasq", "event"])
  end

  test "lease events publish the event and the leases" do
    File.write!(@lease_path, "0 aa:bb:cc:dd:ee:ff 192.168.24.100 printer *\n")

    Notifications.dispatch(
      ["add", "aa:bb:cc:dd:ee:ff", "192.168.24.100", "printer"],
      %{},
      @context
    )

    assert %Event{name: "add", mac: "aa:bb:cc:dd:ee:ff"} =
             VintageNet.get(["interface", @ifname, "dnsmasq", "event"])

    assert [%{lease_mac: "aa:bb:cc:dd:ee:ff", leasetime: :infinity}] =
             VintageNet.get(["interface", @ifname, "dhcpd", "leases"])
  end
end
