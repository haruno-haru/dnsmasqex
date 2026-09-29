# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.IPv6Test do
  use ExUnit.Case

  alias Dnsmasqex.Config
  alias Dnsmasqex.Notifications
  alias Dnsmasqex.Server

  @moduletag :tmp_dir

  test "requires interface listening for router advertisements" do
    for mode <- [:slaac, :stateless, :ra_only] do
      dhcpv6 =
        if mode == :slaac,
          do: %{mode: mode, start: "fd12::10", end: "fd12::99"},
          else: %{mode: mode}

      config = %{
        ipv6: %{method: :static, address: "fd12::1", prefix_length: 64},
        dnsmasq: %{dhcpv6: dhcpv6}
      }

      assert Config.normalize(config).dnsmasq.listen_mode == :interface

      assert_raise ArgumentError, ~r/router advertisements require/, fn ->
        Config.normalize(put_in(config, [:dnsmasq, :listen_mode], :addresses))
      end
    end
  end

  @duid "00:03:00:01:aa:bb:cc:dd:ee:ff"
  @config %{
    type: Dnsmasqex,
    technology: Dnsmasqex.Test.WiredTechnology,
    ipv4: %{method: :disabled},
    ipv6: %{method: :static, address: "fd12:3456:789a:1::1", prefix_length: 64},
    dnsmasq: %{
      dhcpv6: %{start: "fd12:3456:789a:1::10", end: "fd12:3456:789a:1::99"},
      enable_ra: true,
      options6: %{dns: ["fd12:3456:789a:1::1"], search: ["lan"]},
      static_leases6: [%{duid: @duid, ip: "fd12:3456:789a:1::100", hostname: "esp32"}],
      records: [{"esp32.lan", "fd12:3456:789a:1::100"}]
    }
  }

  test "configures an IPv6-only interface and cleans up its address", %{tmp_dir: tmpdir} do
    raw = Dnsmasqex.to_raw_config("eth1", @config, tmpdir: tmpdir)
    normalized = raw.source_config
    assert Dnsmasqex.normalize(normalized) == normalized
    assert normalized.ipv4 == %{method: :disabled}

    assert raw.up_cmds == [
             :wired_up,
             {:run, "ip", ["-6", "addr", "add", "fd12:3456:789a:1::1/64", "dev", "eth1"]}
           ]

    assert hd(raw.down_cmds) ==
             {:run_ignore_errors, "ip",
              ["-6", "addr", "del", "fd12:3456:789a:1::1/64", "dev", "eth1"]}

    [{_, contents} | _] = raw.files
    assert contents =~ "listen-address=fd12:3456:789a:1::1\nbind-dynamic\n"
    assert contents =~ "dhcp-range=fd12:3456:789a:1::10,fd12:3456:789a:1::99,64\nenable-ra\n"
    refute contents =~ "dhcp-range=192."

    assert {_path, "id:#{@duid},[fd12:3456:789a:1::100],esp32,infinite\n"} =
             Config.runtime_file(:static_leases6, normalized.dnsmasq, tmpdir, "eth1")

    assert {_path, "option6:dns-server,[fd12:3456:789a:1::1]\noption6:domain-search,lan\n"} =
             Config.runtime_file(:options6, normalized.dnsmasq, tmpdir, "eth1")
  end

  test "serves IPv4 and IPv6 concurrently", %{tmp_dir: tmpdir} do
    config = %{
      @config
      | ipv4: %{method: :static, address: "192.168.24.1", prefix_length: 24},
        dnsmasq: Map.merge(@config.dnsmasq, %{start: "192.168.24.10", end: "192.168.24.99"})
    }

    [{_, contents} | _] = Dnsmasqex.to_raw_config("eth1", config, tmpdir: tmpdir).files
    assert contents =~ "listen-address=192.168.24.1\nlisten-address=fd12:3456:789a:1::1\n"
    assert contents =~ "dhcp-range=192.168.24.10,192.168.24.99\n"
    assert contents =~ "dhcp-range=fd12:3456:789a:1::10,fd12:3456:789a:1::99,64\n"
  end

  test "serves DNS over IPv6 without DHCP or advertisements", %{tmp_dir: tmpdir} do
    config = %{@config | dnsmasq: %{records: [{"esp32.lan", "fd12:3456:789a:1::100"}]}}
    [{_, contents} | _] = Dnsmasqex.to_raw_config("eth1", config, tmpdir: tmpdir).files
    refute contents =~ "dhcp-range="
    refute contents =~ "enable-ra"
  end

  test "generates SLAAC, stateless DHCPv6 and static-only ranges", %{tmp_dir: tmpdir} do
    for {dnsmasq, expected} <- [
          {%{dhcpv6: %{mode: :ra_only}, ra_lifetime: 0}, "fd12:3456:789a:1::,ra-only,64"},
          {%{dhcpv6: %{mode: :stateless, lease_time: 3600}},
           "fd12:3456:789a:1::,ra-stateless,64,3600"},
          {%{static_leases6: @config.dnsmasq.static_leases6}, "fd12:3456:789a:1::,static,64"},
          {%{dhcpv6: Map.merge(@config.dnsmasq.dhcpv6, %{mode: :slaac, lease_time: :infinite})},
           "fd12:3456:789a:1::10,fd12:3456:789a:1::99,slaac,64,infinite"}
        ] do
      config = %{@config | dnsmasq: dnsmasq}
      normalized = Dnsmasqex.normalize(config)
      assert Dnsmasqex.normalize(normalized) == normalized
      [{_, contents} | _] = Dnsmasqex.to_raw_config("eth1", config, tmpdir: tmpdir).files
      assert contents =~ "dhcp-range=#{expected}\n"
      if dnsmasq[:ra_lifetime] == 0, do: assert(contents =~ "ra-param=eth1,0,0\n")
    end
  end

  test "rejects incompatible modes, wrong subnets and unsafe addresses" do
    for dhcpv6 <- [
          nil,
          %{},
          %{start: "fd12:3456:789a:1::10"},
          %{mode: :unknown},
          %{mode: :static, start: "fd12:3456:789a:1::10"},
          %{mode: :ra_only, end: "fd12:3456:789a:1::99"},
          %{mode: :stateful, start: "fd12:3456:789a:1::99", end: "fd12:3456:789a:1::10"},
          %{start: "fd12:3456:789a:1::", end: "fd12:3456:789a:1::99"},
          %{start: "fd12:3456:789a:1::1", end: "fd12:3456:789a:1::99"},
          %{start: "fd12:3456:789a:2::10", end: "fd12:3456:789a:2::99"},
          %{start: "192.168.24.10", end: "192.168.24.99"},
          Map.put(@config.dnsmasq.dhcpv6, :lease_time, 60),
          Map.put(@config.dnsmasq.dhcpv6, :typo, true)
        ] do
      assert_raise ArgumentError, fn ->
        Dnsmasqex.normalize(%{@config | dnsmasq: %{dhcpv6: dhcpv6}})
      end
    end

    for address <- [
          "::",
          "::1",
          "fe80::1",
          "ff02::1",
          "::ffff:192.168.24.1",
          "192.168.24.1",
          "fd00::1\nserver=bad"
        ] do
      assert_raise ArgumentError, fn ->
        Dnsmasqex.normalize(put_in(@config.ipv6.address, address))
      end
    end

    for prefix <- [-1, 0, 63, 65, 129, 64.0] do
      assert_raise ArgumentError, fn ->
        Dnsmasqex.normalize(put_in(@config.ipv6.prefix_length, prefix))
      end
    end

    assert_raise ArgumentError, fn -> Dnsmasqex.normalize(Map.delete(@config, :ipv6)) end

    assert_raise ArgumentError, fn ->
      Dnsmasqex.normalize(%{@config | dnsmasq: %{enable_ra: true}})
    end

    assert_raise ArgumentError, fn ->
      Dnsmasqex.normalize(put_in(@config.dnsmasq.enable_ra, "true"))
    end

    assert_raise ArgumentError, fn ->
      Dnsmasqex.normalize(put_in(@config.dnsmasq.dhcpv6, %{mode: :ra_only}))
    end
  end

  test "rejects pools containing the server, even if both endpoints are valid" do
    config = put_in(@config.ipv6.address, "fd12:3456:789a:1::50")
    assert_raise ArgumentError, fn -> Dnsmasqex.normalize(config) end
  end

  test "rejects unsupported IPv6 interface fields instead of silently dropping them" do
    for ipv6 <- [
          Map.put(@config.ipv6, :gateway, "fd12:3456:789a:1::2"),
          Map.put(@config.ipv6, :prefix_lenght, 64),
          %{method: :disabled, address: "fd12:3456:789a:1::1"}
        ] do
      assert_raise ArgumentError, ~r/Invalid IPv6 interface configuration/, fn ->
        Dnsmasqex.normalize(%{@config | ipv6: ipv6, dnsmasq: %{}})
      end
    end

    config = %{@config | ipv6: %{method: :disabled}, dnsmasq: %{}}
    assert Dnsmasqex.normalize(config).ipv6 == %{method: :disabled}
  end

  test "allows a longer DHCPv6 prefix when router advertisements are disabled" do
    config =
      @config |> put_in([:ipv6, :prefix_length], 112) |> put_in([:dnsmasq, :enable_ra], false)

    assert Dnsmasqex.normalize(config).ipv6.prefix_length == 112
  end

  test "validates router lifetimes and requires advertisements" do
    for lifetime <- [0, 600, 1800, 9000] do
      assert Dnsmasqex.normalize(put_in(@config, [:dnsmasq, :ra_lifetime], lifetime)).dnsmasq.ra_lifetime ==
               lifetime
    end

    for lifetime <- [-1, 1, 599, 9001, 0.0, "600"] do
      assert_raise ArgumentError, fn ->
        Dnsmasqex.normalize(put_in(@config, [:dnsmasq, :ra_lifetime], lifetime))
      end
    end

    config =
      @config |> put_in([:dnsmasq, :enable_ra], false) |> put_in([:dnsmasq, :ra_lifetime], 0)

    assert_raise ArgumentError, fn -> Dnsmasqex.normalize(config) end
  end

  test "validates DUIDs, static addresses, options and directive injection" do
    lease = hd(@config.dnsmasq.static_leases6)

    for leases <- [
          [lease, lease],
          [lease, %{lease | duid: "00:03:00:01:aa:bb:cc:dd:ee:01"}],
          [%{lease | duid: "bad"}],
          [%{lease | duid: @duid <> "\nconf-file=/tmp/x"}],
          [%{lease | hostname: "infinite"}],
          [%{lease | ip: "fd12:3456:789a:1::1"}],
          [%{lease | ip: "fd12:3456:789a:1::"}],
          [%{lease | ip: "fd12:3456:789a:2::100"}],
          [Map.put(lease, :lease_time, 1)],
          [Map.put(lease, :unknown, true)]
        ] do
      assert_raise ArgumentError, fn ->
        Dnsmasqex.normalize(put_in(@config.dnsmasq.static_leases6, leases))
      end
    end

    for options <- [
          %{23 => "[::]", dns: []},
          %{24 => "lan", search: ["lan"]},
          %{56 => "[::]", ntp: ["::"]},
          %{dns: "192.168.24.1"},
          %{router: "fd00::1"},
          %{search: "bad name"},
          %{65_536 => "1"},
          %{23 => "[::]\nconf-file=/tmp/x"},
          %{23 => String.duplicate("a", 1024)}
        ] do
      assert_raise ArgumentError, fn ->
        Dnsmasqex.normalize(put_in(@config.dnsmasq.options6, options))
      end
    end
  end

  test "reservations cannot use another server address on an overlapping prefix" do
    config =
      put_in(@config, [:ipv6, :addresses], [
        %{address: "fd12:3456:789a:1::100", prefix_length: 64}
      ])

    assert_raise ArgumentError, ~r/interface's.*address/, fn ->
      Dnsmasqex.normalize(config)
    end
  end

  @tag :dnsmasq
  test "changes IPv6 reservations and options without disturbing IPv4", %{tmp_dir: tmpdir} do
    ifname = "dnsmasq_ipv6"

    config =
      @config
      |> Map.put(:ipv4, %{method: :static, address: "192.168.24.1", prefix_length: 24})
      |> put_in([:dnsmasq, :static_leases], [{"aa:bb:cc:dd:ee:ff", "192.168.24.100"}])
      |> put_in([:dnsmasq, :options], %{dns: ["192.168.24.1"]})
      |> Dnsmasqex.normalize()

    on_exit(fn -> Notifications.clear(ifname) end)
    start_supervised!({Server, ifname: ifname, tmpdir: tmpdir, config: config})
    path = Config.runtime_path(:static_leases6, tmpdir, ifname)
    original = File.read!(path)

    assert {:error, {:duid_in_use, _}} =
             Server.update(ifname, :add_static_lease6, [hd(@config.dnsmasq.static_leases6)])

    assert File.read!(path) == original
    assert {:error, _} = Server.update(ifname, :put_option6, [:dns, "192.168.24.1"])

    lease = %{duid: @duid, ip: "fd12:3456:789a:1::101"}
    assert :ok = Server.update(ifname, :put_static_lease6, [lease])
    assert File.read!(path) == "id:#{@duid},[fd12:3456:789a:1::101],infinite\n"
    assert :ok = Server.update(ifname, :remove_static_lease6, [String.upcase(@duid)])
    assert File.read!(path) == ""
    assert :ok = Server.update(ifname, :static_leases6, [[lease]])
    assert :ok = Server.update(ifname, :put_option6, [:dns, ["::"]])

    assert File.read!(Config.runtime_path(:options6, tmpdir, ifname)) =~
             "option6:dns-server,[::]\n"

    assert :ok = Server.update(ifname, :put_option6, [23, "[fd12:3456:789a:1::53]"])
    refute Map.has_key?(VintageNet.get(["interface", ifname, "dnsmasq", "options6"]), :dns)

    options_path = Config.runtime_path(:options6, tmpdir, ifname)
    previous_file = File.read!(options_path)
    previous_value = VintageNet.get(["interface", ifname, "dnsmasq", "options6"])

    assert {:error, {:invalid_configuration, _}} =
             Server.update(ifname, :put_option6, [23, "[not-an-address]"])

    assert File.read!(options_path) == previous_file
    assert VintageNet.get(["interface", ifname, "dnsmasq", "options6"]) == previous_value

    assert :ok = Server.update(ifname, :delete_option6, [:dns])

    assert File.read!(Config.runtime_path(:options6, tmpdir, ifname)) ==
             "option6:domain-search,lan\n"

    assert File.read!(Config.runtime_path(:options, tmpdir, ifname)) ==
             "option:dns-server,192.168.24.1\n"

    assert File.read!(Config.runtime_path(:static_leases, tmpdir, ifname)) ==
             "aa:bb:cc:dd:ee:ff,192.168.24.100,infinite\n"

    assert VintageNet.get(["interface", ifname, "dnsmasq", "static_leases6"]) != []
  end

  @tag :dnsmasq
  test "IPv6 reservation changes cannot take another client's address", %{tmp_dir: tmpdir} do
    ifname = "dnsmasq_ipv6_conflicts"
    config = Dnsmasqex.normalize(@config)
    on_exit(fn -> Notifications.clear(ifname) end)
    start_supervised!({Server, ifname: ifname, tmpdir: tmpdir, config: config})
    [existing] = config.dnsmasq.static_leases6
    lease = %{duid: "00:03:00:01:aa:bb:cc:dd:ee:01", ip: existing.ip}

    for command <- [:add_static_lease6, :put_static_lease6] do
      assert {:error, {:ip_in_use, ^existing}} = Server.update(ifname, command, [lease])
    end

    # Inserting with put is allowed, but replacing it must still respect the other reservation.
    assert :ok =
             Server.update(ifname, :put_static_lease6, [%{lease | ip: "fd12:3456:789a:1::101"}])

    assert {:error, {:ip_in_use, ^existing}} = Server.update(ifname, :put_static_lease6, [lease])

    assert [^existing, %{duid: duid}] =
             VintageNet.get(["interface", ifname, "dnsmasq", "static_leases6"])

    assert duid == lease.duid
  end

  test "doesn't enable address allocation through a runtime update", %{tmp_dir: tmpdir} do
    config = Dnsmasqex.normalize(%{@config | dnsmasq: %{dhcpv6: %{mode: :stateless}}})
    ifname = "dnsmasq_stateless"
    on_exit(fn -> Notifications.clear(ifname) end)
    start_supervised!({Server, ifname: ifname, tmpdir: tmpdir, config: config})

    assert {:error, :dhcpv6_disabled} =
             Server.update(ifname, :static_leases6, [@config.dnsmasq.static_leases6])
  end

  test "a hosts directory doesn't enable DHCPv4 on an IPv6-only interface", %{tmp_dir: tmpdir} do
    config =
      @config
      |> put_in([:dnsmasq, :hosts_dir], Path.join(tmpdir, "hosts"))
      |> Dnsmasqex.normalize()

    ifname = "dnsmasq_ipv6_hosts"
    on_exit(fn -> Notifications.clear(ifname) end)
    start_supervised!({Server, ifname: ifname, tmpdir: tmpdir, config: config})

    for {command, args} <- [
          static_leases: [[]],
          add_static_lease: [{"aa:bb:cc:dd:ee:ff", "192.168.24.100"}],
          put_static_lease: [{"aa:bb:cc:dd:ee:ff", "192.168.24.100"}],
          remove_static_lease: ["aa:bb:cc:dd:ee:ff"]
        ] do
      assert {:error, :dhcp_disabled} = Server.update(ifname, command, args)
    end
  end

  @tag :dnsmasq
  test "failed IPv6 updates preserve files, published values and subsequent changes", %{
    tmp_dir: tmpdir
  } do
    ifname = "dnsmasq_ipv6_errors"
    config = Dnsmasqex.normalize(@config)
    on_exit(fn -> Notifications.clear(ifname) end)
    start_supervised!({Server, ifname: ifname, tmpdir: tmpdir, config: config})
    path = Config.runtime_path(:static_leases6, tmpdir, ifname)
    property = ["interface", ifname, "dnsmasq", "static_leases6"]
    original = File.read!(path)
    lease = %{duid: "00:03:00:01:aa:bb:cc:dd:ee:01", ip: "fd12:3456:789a:1::101"}

    assert {:error, message} = Server.update(ifname, :add_static_lease6, [%{lease | ip: "::1"}])
    assert message =~ "Expected a global or unique-local IPv6 address"

    File.mkdir!(path <> ".new")
    assert {:error, :eisdir} = Server.update(ifname, :add_static_lease6, [lease])
    assert File.read!(path) == original
    assert VintageNet.get(property) == config.dnsmasq.static_leases6

    File.rmdir!(path <> ".new")
    assert :ok = Server.update(ifname, :add_static_lease6, [lease])
    assert File.read!(path) == original <> "id:#{lease.duid},[#{lease.ip}],infinite\n"
    assert length(VintageNet.get(property)) == 2
  end
end
