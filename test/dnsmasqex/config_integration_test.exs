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
        {"DHCP options",
         %{
           start: "192.168.24.10",
           end: "192.168.24.99",
           options: %{
             43 => "4d:53:46:54",
             252 => "\"http://192.168.24.1/wpad.dat\"",
             router: [],
             dns: ["192.168.24.1"],
             ntp: ["192.168.24.1"],
             search: ["lan", "example.com"],
             domain: "lan",
             hostname: "client",
             mtu: 1400
           }
         }},
        {"upstream DNS",
         %{
           name_servers: ["1.1.1.1", "2606:4700:4700::1111"],
           forward_domains: [{"corp.example.com", ["10.0.0.53"]}, {"lan", []}]
         }},
        {"local domain", %{domain: "lan", start: "192.168.24.10", end: "192.168.24.99"}},
        {"DNS records",
         %{
           domain: "lan",
           records: [{"pi", "192.168.24.1"}, {"pi6.lan", "fd00::1"}],
           domain_records: [{"*.example.com", "192.168.24.2"}, {"#", "192.168.24.1"}],
           cnames: [{"www.lan", "pi.lan"}],
           srv_records: [
             {"_http._tcp.lan", "pi.lan", 80},
             {"_ipp._tcp.lan", "pi.lan", 631, 10, 5}
           ],
           txt_records: [{"pi.lan", ["v=1", ~s(say "hi" \\ bye)]}],
           mx_records: [{"lan", "pi.lan"}, {"example.com", "pi.lan", 10}]
         }},
        {"map static leases",
         %{
           start: "192.168.24.10",
           end: "192.168.24.99",
           static_leases: [
             %{mac: "aa:bb:cc:dd:ee:01", ip: "192.168.24.101", lease_time: 600},
             %{mac: "aa:bb:cc:dd:ee:02", hostname: "camera"},
             %{mac: "aa:bb:cc:dd:ee:05", ignore: true}
           ]
         }},
        {"static DHCP",
         %{static_leases: [{"aa:bb:cc:dd:ee:ff", "192.168.24.100", "printer"}], lease_time: 3600}}
      ] do
    @dnsmasq dnsmasq

    test "dnsmasq accepts generated #{name} configuration", %{tmp_dir: tmp_dir} do
      check_config(@dnsmasq, tmp_dir)
    end
  end

  test "dnsmasq accepts an authoritative server with its own lease file", %{tmp_dir: tmp_dir} do
    check_config(
      %{
        start: "192.168.24.10",
        end: "192.168.24.99",
        authoritative: true,
        lease_path: Path.join(tmp_dir, "leases/eth1.leases")
      },
      tmp_dir
    )
  end

  test "dnsmasq accepts a hosts directory without an initial lease", %{tmp_dir: tmp_dir} do
    hosts_dir = Path.join(tmp_dir, "hosts directory")
    File.mkdir!(hosts_dir)
    check_config(%{hosts_dir: hosts_dir}, tmp_dir)
  end

  test "dnsmasq accepts nftsets only when built with them", %{tmp_dir: tmp_dir} do
    dnsmasq = %{nftsets: [{["example.com"], ["inet#filter#allowed"]}]}

    case Dnsmasqex.capabilities() do
      {:ok, %{nftset: true}} ->
        check_config(dnsmasq, tmp_dir)

      {:ok, %{nftset: false}} ->
        assert %ExUnit.AssertionError{message: message} =
                 catch_error(check_config(dnsmasq, tmp_dir))

        assert message =~ "recompile with HAVE_NFTSET"
    end
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

    # dnsmasq --test doesn't read these files, so check their lines as the options they hold
    runtime_conf = Path.join(tmp_dir, "runtime.conf")

    runtime_directives =
      for {option, directive} <- [static_leases: "dhcp-host", options: "dhcp-option"],
          {_path, contents} = Config.runtime_file(option, config.dnsmasq, tmp_dir, "eth1"),
          line <- String.split(contents, "\n", trim: true),
          into: "",
          do: "#{directive}=#{line}\n"

    File.write!(runtime_conf, runtime_directives)

    for conf <- [Config.conf_path(tmp_dir, "eth1"), runtime_conf] do
      {output, status} = System.cmd("dnsmasq", ["--test", "-C", conf], stderr_to_stdout: true)
      assert status == 0, output
    end
  end
end
