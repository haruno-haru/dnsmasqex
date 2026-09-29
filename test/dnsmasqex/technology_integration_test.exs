# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.TechnologyIntegrationTest do
  use ExUnit.Case, async: true

  alias Dnsmasqex.Notifications
  alias VintageNet.Interface

  test "preserves Ethernet addressing, MAC selection and connectivity monitoring" do
    config = %{
      type: Dnsmasqex,
      technology: VintageNetEthernet,
      mac_address: "02:00:00:00:00:01",
      ipv4: %{method: :static, address: "192.0.2.1", netmask: "255.255.255.0"},
      dnsmasq: %{start: "192.0.2.100", end: "192.0.2.110"}
    }

    assert {:ok, raw} = Interface.to_raw_config("eth1", config)

    assert raw.source_config.ipv4 == %{
             method: :static,
             address: {192, 0, 2, 1},
             prefix_length: 24
           }

    assert raw.source_config.technology == VintageNetEthernet
    assert raw.type == Dnsmasqex
    assert raw.required_ifnames == ["eth1"]
    assert {:run, "ip", ["link", "set", "eth1", "address", "02:00:00:00:00:01"]} in raw.up_cmds
    assert {VintageNet.Connectivity.LANChecker, "eth1"} in raw.child_specs
    assert {:run, "ip", ["link", "set", "eth1", "down"]} in raw.down_cmds
    assert {:fun, Notifications, :clear, ["eth1"]} in raw.down_cmds
    assert Dnsmasqex.normalize(raw.source_config) == raw.source_config
  end

  test "replaces the WiFi cookbook DHCP server while retaining its AP and supervisor" do
    assert {:ok, wifi} = VintageNetWiFi.Cookbook.open_access_point("dnsmasqex-test")

    config =
      wifi
      |> Map.delete(:dhcpd)
      |> Map.merge(%{type: Dnsmasqex, technology: VintageNetWiFi, dnsmasq: wifi.dhcpd})

    assert {:ok, raw} = Interface.to_raw_config("wlan0", config)
    assert raw.source_config.technology == VintageNetWiFi
    assert raw.restart_strategy == :rest_for_one
    assert raw.required_ifnames == ["wlan0"]
    assert Dnsmasqex.normalize(raw.source_config) == raw.source_config

    children = Enum.map(raw.child_specs, &Supervisor.child_spec(&1, []))
    assert %{start: {VintageNetWiFi.WPASupplicant, :start_link, [options]}} = hd(children)
    assert options[:ifname] == "wlan0"
    assert options[:ap_mode]
    refute Enum.any?(children, &(&1.id in [:udhcpd, :dnsd]))
    assert Enum.count(children, &(&1.id == :dnsmasq)) == 1

    {path, supplicant} = Enum.find(raw.files, fn {path, _} -> path =~ "wpa_supplicant.conf." end)
    assert path == options[:wpa_supplicant_conf_path]
    assert supplicant =~ "mode=2"
    assert supplicant =~ "ssid=\"dnsmasqex-test\""
    assert Enum.any?(raw.cleanup_files, &String.ends_with?(&1, "/wlan0"))
    assert {:fun, Notifications, :clear, ["wlan0"]} in raw.down_cmds

    {_, dnsmasq} = Enum.find(raw.files, fn {path, _} -> path =~ "dnsmasq.conf." end)
    assert dnsmasq =~ "dhcp-range=192.168.24.10,192.168.24.250"

    assert {:error, reason} =
             Interface.to_raw_config("wlan0", Map.put(config, :dhcpd, wifi.dhcpd))

    assert reason =~ ":dhcpd"
  end
end
