# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.ConfigTest do
  use ExUnit.Case, async: true

  alias Dnsmasqex.Config

  @config %{
    ipv4: %{method: :static, address: {192, 168, 24, 1}, prefix_length: 24},
    dnsmasq: %{}
  }

  test "requires IPv4 and a valid prefix even when serving only DNS" do
    for ipv4 <- [
          %{method: :static, address: {0, 0, 0, 0, 0, 0, 0, 1}, prefix_length: 24},
          %{@config.ipv4 | prefix_length: -1},
          %{@config.ipv4 | prefix_length: 33},
          %{@config.ipv4 | prefix_length: 24.0}
        ] do
      assert_raise ArgumentError, fn -> Config.normalize(%{@config | ipv4: ipv4}) end
    end
  end

  test "rejects hostnames parsed as lease times and overlong labels" do
    for hostname <- ["1H", "120S", "2M", "3D", "4W", String.duplicate("a", 64)] do
      dnsmasq = %{static_leases: [{"aa:bb:cc:dd:ee:ff", "192.168.24.10", hostname}]}
      assert_raise ArgumentError, fn -> Config.normalize(%{@config | dnsmasq: dnsmasq}) end
    end
  end

  test "rejects duplicate static addresses and MAC addresses" do
    for leases <- [
          [
            {"aa:bb:cc:dd:ee:ff", "192.168.24.10"},
            {"aa:bb:cc:dd:ee:01", {192, 168, 24, 10}, "printer"}
          ],
          [
            {"aa:bb:cc:dd:ee:ff", "192.168.24.10"},
            {"AA:BB:CC:DD:EE:FF", "192.168.24.11"}
          ]
        ] do
      assert_raise ArgumentError, fn ->
        Config.normalize(%{@config | dnsmasq: %{static_leases: leases}})
      end
    end
  end

  test "rejects invalid DNS record names" do
    for name <- [
          "host\0.example",
          "host\".example",
          "host\x01.example",
          "host..example",
          String.duplicate("a", 64) <> ".example",
          Enum.join(List.duplicate(String.duplicate("a", 63), 4), ".")
        ] do
      assert_raise ArgumentError, fn ->
        Config.normalize(%{@config | dnsmasq: %{records: [{name, "192.168.24.1"}]}})
      end
    end
  end

  test "rejects static leases for the server, network, and broadcast addresses" do
    for ip <- ["192.168.24.0", "192.168.24.1", "192.168.24.255"] do
      assert_raise ArgumentError, fn ->
        Config.normalize(%{@config | dnsmasq: %{static_leases: [{"aa:bb:cc:dd:ee:ff", ip}]}})
      end
    end
  end

  test "accepts the peer address on a point-to-point subnet" do
    config = %{
      @config
      | ipv4: %{@config.ipv4 | prefix_length: 31},
        dnsmasq: %{static_leases: [{"aa:bb:cc:dd:ee:ff", "192.168.24.0"}]}
    }

    assert %{dnsmasq: %{static_leases: [{_, {192, 168, 24, 0}}]}} = Config.normalize(config)
  end

  test "preserves supported DNS selectors and service labels" do
    records =
      for name <- [
            "*",
            ".",
            ".example.com",
            "*.example.com",
            "*example.com",
            "_service.example.com",
            "example.com."
          ] do
        {name, {192, 168, 24, 1}}
      end

    assert %{dnsmasq: %{records: ^records}} =
             Config.normalize(%{@config | dnsmasq: %{records: records}})
  end

  test "rejects paths that dnsmasq would truncate or reinterpret" do
    for path <- ["/data/hosts\0suffix", "/data/hosts #suffix", "/data/\"hosts\"", "/data/hosts "] do
      assert_raise ArgumentError, fn ->
        Config.normalize(%{@config | dnsmasq: %{hosts_dir: path}})
      end
    end
  end

  test "rejects finite lease times that overflow dnsmasq's lease field" do
    for lease_time <- [0xFFFFFFFF, 0x100000078] do
      assert_raise ArgumentError, fn ->
        Config.normalize(%{@config | dnsmasq: %{lease_time: lease_time}})
      end
    end
  end
end
