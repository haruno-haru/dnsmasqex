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

  test "rejects unknown options even when the interface cannot run dnsmasq" do
    for ipv4 <- [@config.ipv4, %{method: :disabled}],
        option <- [:dnssec, :portt, :cache_sizee, :startt] do
      assert_raise ArgumentError, ~r/Unsupported dnsmasq options/, fn ->
        Config.normalize(%{ipv4: ipv4, dnsmasq: %{option => true}})
      end
    end
  end

  test "preserves the interface scope of IPv6 upstreams through normalization and rendering" do
    config =
      Config.normalize(%{
        @config
        | dnsmasq: %{
            name_servers: ["fe80::1%eth0", "1.1.1.1"],
            forward_domains: [{"lan", ["fe80::2%eth1"]}]
          }
      })

    assert Config.normalize(config) == config
    assert config.dnsmasq.name_servers == ["fe80::1%eth0", {1, 1, 1, 1}]

    raw =
      Config.add_config(
        %VintageNet.Interface.RawConfig{
          ifname: "eth1",
          type: Dnsmasqex,
          source_config: config,
          required_ifnames: ["eth1"]
        },
        config,
        tmpdir: "/tmp"
      )

    [{_, contents} | _] = raw.files
    assert contents =~ "server=fe80::1%eth0\n"
    assert contents =~ "server=/lan/fe80::2%eth1\n"

    for server <- [
          nil,
          "fe80::1%",
          "fe80::1%eth0%eth1",
          "fe80::1%eth0\nport=0",
          "192.168.24.1%eth0"
        ] do
      assert_raise ArgumentError, fn ->
        Config.normalize(%{@config | dnsmasq: %{name_servers: [server]}})
      end
    end
  end

  test "rejects DHCPv4 aliases for the same wire option" do
    for options <- [
          %{6 => "192.168.24.2", dns: []},
          %{26 => "1400", mtu: 1500},
          %{subnet: "255.255.255.0", netmask: "255.255.255.0"}
        ] do
      assert_raise ArgumentError, ~r/Duplicate DHCPv4 option aliases/, fn ->
        Config.normalize(%{@config | dnsmasq: %{options: options}})
      end
    end
  end

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

  test "writes map static leases with their own lease times, names and ignored clients" do
    leases = [
      {"aa:bb:cc:dd:ee:00", "192.168.24.100"},
      %{mac: "AA:BB:CC:DD:EE:01", ip: "192.168.24.101", lease_time: 600},
      %{mac: "aa:bb:cc:dd:ee:02", hostname: "camera"},
      %{mac: "aa:bb:cc:dd:ee:03", ip: "192.168.24.103", hostname: "printer"},
      %{mac: "aa:bb:cc:dd:ee:04", lease_time: :infinite},
      %{mac: "aa:bb:cc:dd:ee:05", ignore: true}
    ]

    %{dnsmasq: dnsmasq} = Config.normalize(%{@config | dnsmasq: %{static_leases: leases}})

    assert Enum.at(dnsmasq.static_leases, 1) == %{
             mac: "aa:bb:cc:dd:ee:01",
             ip: {192, 168, 24, 101},
             lease_time: 600
           }

    assert {_path,
            """
            aa:bb:cc:dd:ee:00,192.168.24.100,infinite
            aa:bb:cc:dd:ee:01,192.168.24.101,600
            aa:bb:cc:dd:ee:02,camera
            aa:bb:cc:dd:ee:03,192.168.24.103,printer,infinite
            aa:bb:cc:dd:ee:04,infinite
            aa:bb:cc:dd:ee:05,ignore
            """} = Config.runtime_file(:static_leases, dnsmasq, "/tmp", "eth1")
  end

  test "rejects map static leases dnsmasq would misread" do
    for lease <- [
          %{mac: "aa:bb:cc:dd:ee:ff"},
          %{ip: "192.168.24.10"},
          %{mac: "aa:bb:cc:dd:ee:ff", ignore: true, ip: "192.168.24.10"},
          %{mac: "aa:bb:cc:dd:ee:ff", ignore: false},
          %{mac: "aa:bb:cc:dd:ee:ff", lease_time: 60},
          %{mac: "aa:bb:cc:dd:ee:ff", hostname: "ignore"},
          %{mac: "aa:bb:cc:dd:ee:ff", ip: "192.168.24.10", tag: "known"}
        ] do
      assert_raise ArgumentError, fn ->
        Config.normalize(%{@config | dnsmasq: %{static_leases: [lease]}})
      end
    end

    assert_raise ArgumentError, ~r/Duplicate IP/, fn ->
      Config.normalize(%{
        @config
        | dnsmasq: %{
            static_leases: [
              {"aa:bb:cc:dd:ee:00", "192.168.24.10"},
              %{mac: "aa:bb:cc:dd:ee:01", ip: "192.168.24.10"}
            ]
          }
      })
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

    domain_records = [{"#", {192, 168, 24, 1}} | records]

    assert %{dnsmasq: %{domain_records: ^domain_records, forward_domains: forwards}} =
             Config.normalize(%{
               @config
               | dnsmasq: %{
                   domain_records: domain_records,
                   forward_domains: Enum.map(records, fn {name, ip} -> {name, [ip]} end)
                 }
             })

    assert Enum.map(forwards, &elem(&1, 0)) == Enum.map(records, &elem(&1, 0))
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

  test "normalizes upstream name servers like VintageNet's IPv4 name servers" do
    assert %{
             name_servers: [{1, 1, 1, 1}],
             forward_domains: [{"corp.example.com", [{10, 0, 0, 53}]}, {"lan", []}]
           } =
             Config.normalize(%{
               @config
               | dnsmasq: %{
                   name_servers: "1.1.1.1",
                   forward_domains: [{"corp.example.com", "10.0.0.53"}, {"lan", []}]
                 }
             }).dnsmasq
  end

  test "rejects invalid upstream name servers" do
    for dnsmasq <- [
          %{name_servers: ["dns.example.com"]},
          %{forward_domains: [{"bad domain", "10.0.0.53"}]},
          %{forward_domains: [{"corp.example.com", "not an ip"}]},
          %{forward_domains: %{"corp.example.com" => "10.0.0.53"}},
          %{forward_domains: ["corp.example.com"]}
        ] do
      assert_raise ArgumentError, fn -> Config.normalize(%{@config | dnsmasq: dnsmasq}) end
    end
  end

  test "rejects DNS records dnsmasq would misread" do
    for dnsmasq <- [
          %{records: [{"*.example.com", "192.168.24.1"}]},
          %{records: [{"pi.lan", "pi"}]},
          %{records: [{"pi.lan", {192, 168, 24, 1.5}}]},
          %{name_servers: [{0, 0, 0, 0, 0, 0, 0, 1.5}]},
          %{domain_records: [{"bad name", "192.168.24.1"}]},
          %{cnames: [{"www.lan", "bad,target"}]},
          %{cnames: [{"www.lan", "pi.lan"}, {"WWW.LAN", "pi.lan"}]},
          %{cnames: [{"www.lan", "WWW.LAN"}]},
          %{cnames: [{"www.lan", "PI.LAN"}, {"pi.lan", "www.lan"}]},
          %{srv_records: [{"_http._tcp.lan", "pi.lan", 65_536}]},
          %{srv_records: [{"_http._tcp.lan", "pi.lan", 80, 1}]},
          %{txt_records: [{"pi.lan", "line\nbreak"}]},
          %{txt_records: [{"pi.lan", String.duplicate("a", 256)}]},
          %{txt_records: [{"pi.lan", 1}]},
          %{mx_records: [{"lan", "mail.lan", -1}]},
          %{cnames: %{"www.lan" => "pi.lan"}}
        ] do
      assert_raise ArgumentError, fn -> Config.normalize(%{@config | dnsmasq: dnsmasq}) end
    end
  end

  test "rejects values that would make dnsmasq split a line" do
    long_name = Enum.map_join([63, 63, 63, 61], ".", &String.duplicate("a", &1))
    shared_suffix = Enum.map_join(1..4, ".", fn _ -> String.duplicate("s", 49) end)
    long_path = "/" <> Enum.join(List.duplicate(String.duplicate("d", 100), 11), "/")

    for dnsmasq <- [
          %{options: %{search: for(i <- 1..10, do: "h#{i}." <> shared_suffix)}},
          %{options: %{43 => String.duplicate("ab:", 400)}},
          %{options: %{43 => "value" <> String.duplicate(" ", 1024)}},
          %{nftsets: [{List.duplicate(long_name, 5), ["inet#filter#allowed"]}]},
          %{hosts_dir: long_path},
          %{lease_path: long_path}
        ] do
      assert_raise ArgumentError, ~r/1024-byte line limit/, fn ->
        Config.normalize(%{@config | dnsmasq: dnsmasq})
      end
    end

    assert %{dnsmasq: %{nftsets: [{[_, _, _], _}]}} =
             Config.normalize(%{
               @config
               | dnsmasq: %{nftsets: [{List.duplicate(long_name, 3), "inet#filter#allowed"}]}
             })
  end

  test "rejects DHCP options longer than 255 bytes, counting dnsmasq's name compression" do
    names = fn count ->
      for i <- 1..count, do: "p#{i}#{String.duplicate("q", 28)}.#{String.duplicate("s", 60)}"
    end

    ips = for i <- 1..64, do: {10, 0, 0, i}

    assert %{dnsmasq: %{options: %{search: [_, _, _, _, _], dns: [_ | _]}}} =
             Config.normalize(%{
               @config
               | dnsmasq: %{options: %{search: names.(5), dns: Enum.take(ips, 63)}}
             })

    for options <- [
          %{search: names.(6)},
          %{
            search: [
              String.duplicate("a", 63) <> "." <> String.duplicate("b", 63),
              String.duplicate("c", 63) <> "." <> String.duplicate("d", 63)
            ]
          },
          %{dns: ips},
          %{ntp: ips}
        ] do
      assert_raise ArgumentError, fn ->
        Config.normalize(%{@config | dnsmasq: %{options: options}})
      end
    end
  end

  test "distinguishes nftables names from numeric and punctuation tokens" do
    for name <- [
          ".allowed",
          "_allowed",
          "..",
          "1h2m3s4ms",
          "192.0.2.1",
          "999.999.999.999",
          "09",
          "18446744073709551616",
          "02000000000000000000000",
          "0x10000000000000000"
        ] do
      target = "inet##{name}##{name}"

      assert %{dnsmasq: %{nftsets: [{["example.com"], [^target]}]}} =
               Config.normalize(%{@config | dnsmasq: %{nftsets: [{"example.com", target}]}})
    end

    for name <- [
          ".",
          "1allowed",
          "-filter",
          "1m2h",
          "010",
          "18446744073709551615",
          "01777777777777777777777",
          "0xffffffffffffffff"
        ] do
      assert_raise ArgumentError, fn ->
        Config.normalize(%{
          @config
          | dnsmasq: %{nftsets: [{"example.com", "inet#filter##{name}"}]}
        })
      end
    end
  end

  describe "options" do
    defp options(options),
      do: Config.normalize(%{@config | dnsmasq: %{options: options}}).dnsmasq.options

    test "normalizes like VintageNet's DHCP server options" do
      assert options(%{
               252 => "\"http://192.168.24.1/wpad.dat\"",
               dns: "192.168.24.1",
               router: [],
               ntp: [{192, 168, 24, 1}, "192.168.24.2"],
               search: "lan",
               domain: "lan",
               netmask: "255.255.255.0",
               serverid: "192.168.24.1",
               mtu: 1400
             }) == %{
               252 => "\"http://192.168.24.1/wpad.dat\"",
               dns: [{192, 168, 24, 1}],
               router: [],
               ntp: [{192, 168, 24, 1}, {192, 168, 24, 2}],
               search: ["lan"],
               domain: "lan",
               subnet: {255, 255, 255, 0},
               serverid: {192, 168, 24, 1},
               mtu: 1400
             }
    end

    test "rejects options dnsmasq would override or misread" do
      for options <- [
            %{subnet: "255.255.0.0"},
            %{serverid: "192.168.24.2"},
            %{dns: ["fd00::1"]},
            %{search: ["bad name"]},
            %{domain: "lan\ndhcp-script=/tmp/x"},
            %{mtu: 67},
            %{0 => "00"},
            %{255 => "00"},
            %{43 => "4d:53\ndhcp-script=/tmp/x"},
            %{43 => 1},
            %{unknown: "value"},
            [dns: "192.168.24.1"]
          ] do
        assert_raise ArgumentError, fn -> options(options) end
      end
    end
  end
end
