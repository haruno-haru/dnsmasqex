# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.ConfigIntegrationTest do
  use ExUnit.Case, async: true

  alias VintageNet.Interface.RawConfig
  alias Dnsmasqex.Config

  @moduletag :dnsmasq
  @moduletag :linux
  @moduletag :tmp_dir

  for {name, dnsmasq} <- [
        {"DNS only", %{records: [{"device.example.com", "192.168.24.1"}]}},
        {"infinite DHCP", %{start: "192.168.24.10", end: "192.168.24.99", lease_time: :infinite}},
        {"static DHCP",
         %{static_leases: [{"aa:bb:cc:dd:ee:ff", "192.168.24.100", "printer"}], lease_time: 3600}}
      ] do
    @dnsmasq dnsmasq

    test "dnsmasq accepts generated #{name} configuration", %{tmp_dir: tmp_dir} do
      check_config(@dnsmasq, tmp_dir)
    end
  end

  test "dnsmasq accepts a hosts directory without an initial lease", %{tmp_dir: tmp_dir} do
    hosts_dir = Path.join(tmp_dir, "hosts directory")
    File.mkdir!(hosts_dir)
    check_config(%{hosts_dir: hosts_dir}, tmp_dir)
  end

  defp check_config(dnsmasq, tmp_dir) do
    config =
      Config.normalize(%{
        ipv4: %{method: :static, address: {192, 168, 24, 1}, prefix_length: 24},
        dnsmasq: dnsmasq
      })

    raw_config =
      Config.add_config(
        %RawConfig{
          ifname: "eth1",
          type: Dnsmasqex,
          source_config: config,
          required_ifnames: ["eth1"]
        },
        config,
        tmpdir: tmp_dir
      )

    for {path, contents} <- raw_config.files, do: File.write!(path, contents)

    {output, status} =
      System.cmd("dnsmasq", ["--test", "-C", Config.conf_path(tmp_dir, "eth1")],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
