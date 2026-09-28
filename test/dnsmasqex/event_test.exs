# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.EventTest do
  use ExUnit.Case, async: true

  alias Dnsmasqex.Event

  doctest Event

  test "accepts nonnegative lease durations and ignores invalid values" do
    args = ["add", "aa:bb:cc:dd:ee:ff", "192.168.24.10"]

    for {input, expected} <- [
          {"0", 0},
          {"3600", 3600},
          {"4294967295", 4_294_967_295},
          {"-1", nil},
          {"3600s", nil},
          {"", nil}
        ] do
      assert Event.new(args, %{"DNSMASQ_TIME_REMAINING" => input}).time_remaining == expected
    end
  end

  test "reports the client's request metadata" do
    env = %{
      "DNSMASQ_REQUESTED_OPTIONS" => "1,3,6,15,119",
      "DNSMASQ_USER_CLASS0" => "iPXE",
      "DNSMASQ_USER_CLASS1" => "lab",
      "DNSMASQ_USER_CLASS3" => "after a gap",
      "DNSMASQ_MUD_URL" => "https://example.com/mud",
      "DNSMASQ_CPEWAN_OUI" => "001122",
      "DNSMASQ_CPEWAN_SERIAL" => "ABC123"
    }

    assert %Event{
             requested_options: [1, 3, 6, 15, 119],
             user_classes: ["iPXE", "lab"],
             mud_url: "https://example.com/mud",
             cpewan: %{oui: "001122", serial: "ABC123", class: nil}
           } = Event.new(["add", "aa:bb:cc:dd:ee:ff", "192.168.24.10"], env)
  end

  test "leaves request metadata nil when dnsmasq doesn't report it" do
    assert %Event{requested_options: nil, user_classes: nil, mud_url: nil, cpewan: nil} =
             Event.new(["old", "aa:bb:cc:dd:ee:ff", "192.168.24.10"], %{
               "DNSMASQ_DATA_MISSING" => "1"
             })
  end

  test "ignores malformed requested options" do
    for options <- ["1,,3", "1,256", "one", "1;3"] do
      event =
        Event.new(["add", "aa:bb:cc:dd:ee:ff", "192.168.24.10"], %{
          "DNSMASQ_REQUESTED_OPTIONS" => options
        })

      assert event.requested_options == nil
    end
  end

  test "parses DHCPv6 script arguments and environment as emitted by dnsmasq" do
    duid = "00:03:00:01:aa:bb:cc:dd:ee:ff"
    args = ["add", duid, "fd12:3456:789a:1::10", "esp32"]

    env = %{
      "DNSMASQ_IAID" => "T42",
      "DNSMASQ_SERVER_DUID" => "00:01:00:01:aa:bb:cc:dd",
      "DNSMASQ_MAC" => "aa:bb:cc:dd:ee:ff",
      "DNSMASQ_INTERFACE" => "eth1",
      "DNSMASQ_VENDOR_CLASS_ID" => "1234",
      "DNSMASQ_VENDOR_CLASS0" => "embedded",
      "DNSMASQ_VENDOR_CLASS1" => "ethernet",
      "DNSMASQ_REQUESTED_OPTIONS" => "23,24,256,65535"
    }

    assert %Event{
             duid: ^duid,
             client_id: ^duid,
             iaid: "T42",
             mac: "aa:bb:cc:dd:ee:ff",
             server_duid: "00:01:00:01:aa:bb:cc:dd",
             interface: "eth1",
             vendor_class: nil,
             vendor_class_id: "1234",
             vendor_classes: ["embedded", "ethernet"],
             requested_options: [23, 24, 256, 65_535]
           } = Event.new(args, env)

    assert %Event{duid: ^duid, mac: nil} = Event.new(args, %{})

    assert %Event{requested_options: nil} =
             Event.new(args, %{"DNSMASQ_REQUESTED_OPTIONS" => "65536"})
  end

  test "IPv6 neighbor events still carry MAC addresses" do
    assert %Event{mac: "aa:bb:cc:dd:ee:ff", duid: nil, client_id: nil} =
             Event.new(["arp-add", "aa:bb:cc:dd:ee:ff", "fd12:3456:789a:1::10"], %{})
  end

  test "neighbors don't inherit unrelated DHCP environment fields" do
    env = %{
      "DNSMASQ_CLIENT_ID" => "01:aa:bb:cc:dd:ee:ff",
      "DNSMASQ_MAC" => "aa:bb:cc:dd:ee:01",
      "DNSMASQ_IAID" => "42",
      "DNSMASQ_INTERFACE" => "eth1",
      "DNSMASQ_TIME_REMAINING" => "3600"
    }

    for name <- ["arp-add", "arp-del"], ip <- ["192.168.24.10", "fd12:3456:789a:1::10"] do
      assert Event.new([name, "aa:bb:cc:dd:ee:ff", ip], env) ==
               %Event{name: name, mac: "aa:bb:cc:dd:ee:ff", ip: ip}
    end
  end

  test "lease fields belong to the address family reported by dnsmasq" do
    env = %{
      "DNSMASQ_CLIENT_ID" => "01:aa:bb:cc:dd:ee:ff",
      "DNSMASQ_VENDOR_CLASS" => "ipv4-client",
      "DNSMASQ_CPEWAN_OUI" => "001122",
      "DNSMASQ_IAID" => "42",
      "DNSMASQ_SERVER_DUID" => "00:03:00:01:aa:bb:cc:dd:ee:01",
      "DNSMASQ_VENDOR_CLASS_ID" => "1234",
      "DNSMASQ_VENDOR_CLASS0" => "ipv6-client"
    }

    assert %Event{iaid: nil, server_duid: nil, vendor_class_id: nil, vendor_classes: nil} =
             Event.new(["add", "aa:bb:cc:dd:ee:ff", "192.168.24.10"], env)

    assert %Event{vendor_class: nil, cpewan: nil} =
             Event.new(["add", "00:03:00:01:aa:bb:cc:dd:ee:ff", "fd12:3456:789a:1::10"], env)
  end

  test "malformed addresses aren't interpreted as IPv6 lease identities" do
    for ip <- ["invalid:address", "192.168.24.999", "fd12:::10"] do
      assert Event.new(["add", "aa:bb:cc:dd:ee:ff", ip], %{}) == %Event{name: "add"}
    end
  end
end
