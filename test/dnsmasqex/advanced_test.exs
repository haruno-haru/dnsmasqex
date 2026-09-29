# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.AdvancedTest do
  use ExUnit.Case, async: true

  alias Dnsmasqex.{Config, Directives, Event, IPv6, Leases, Notifications, Preflight, Upstream}
  alias VintageNet.Interface.RawConfig

  @moduletag :tmp_dir
  @base %{ipv4: %{method: :static, address: {192, 0, 2, 1}, prefix_length: 24}, dnsmasq: %{}}

  test "duration-format leases never pretend that a saved length is a remaining time", %{
    tmp_dir: tmpdir
  } do
    contents = """
    600 02:00:00:00:00:02 192.0.2.100 esp32 01:02:00:00:00:00:02
    600 42 fd12::100 esp32v6 00:03:00:01:02:00:00:00:00:02
    0 T43 fd12::101 permanent 00:03:00:01:02:00:00:00:00:02
    """

    for now <- [0, 1_800_000_000, 2_000_000_000] do
      assert [
               %{leasetime: :unknown, lease_length: 600},
               %{leasetime: :unknown, lease_length: 600},
               %{leasetime: :infinity}
             ] = Leases.parse(contents, now, :duration)
    end

    path = Path.join(tmpdir, "leases")
    File.write!(path, contents)
    ifname = "duration-test"
    on_exit(fn -> Notifications.clear(ifname) end)

    Notifications.dispatch(
      ["old", "02:00:00:00:00:02", "192.0.2.100", "esp32"],
      %{"DNSMASQ_LEASE_LENGTH" => "600", "DNSMASQ_TIME_REMAINING" => "583"},
      %{ifname: ifname, lease_path: path, subnets: []}
    )

    assert [
             %{leasetime: 583, lease_client_id: "01:02:00:00:00:00:02"},
             %{leasetime: :unknown},
             %{leasetime: :infinity}
           ] =
             VintageNet.get(["interface", ifname, "dhcpd", "leases"])
  end

  test "retains restart and relay metadata without inventing missing fields" do
    event =
      Event.new(["old", "02:00:00:00:00:02", "192.0.2.100"], %{
        "DNSMASQ_LEASE_EXPIRES" => "1800000600",
        "DNSMASQ_DATA_MISSING" => "1",
        "DNSMASQ_DOMAIN" => "lan",
        "DNSMASQ_RELAY_ADDRESS" => "192.0.2.254",
        "DNSMASQ_CIRCUIT_ID" => "01:02",
        "DNSMASQ_REMOTE_ID" => "03:04",
        "DNSMASQ_SUBSCRIBER_ID" => "05:06"
      })

    assert event.lease_expires == 1_800_000_600
    assert event.data_missing == true
    assert event.relay_address == "192.0.2.254"

    assert {event.domain, event.circuit_id, event.remote_id, event.subscriber_id} ==
             {"lan", "01:02", "03:04", "05:06"}

    assert event.lease_length == nil
  end

  test "reports clock mode and bounds both executable probes", %{tmp_dir: tmpdir} do
    path = Path.join(tmpdir, "dnsmasq")

    File.write!(
      path,
      "#!/bin/sh\necho 'Dnsmasq version 2.93'\necho 'Compile time options: DHCP no-RTC'\n"
    )

    File.chmod!(path, 0o700)
    assert {:ok, %{lease_time_format: :duration}} = Dnsmasqex.capabilities(path)

    File.write!(path, "#!/bin/sh\nexec sleep 60\n")
    assert {:error, "dnsmasq --version timed out"} = Dnsmasqex.capabilities(path, 30)

    assert {:error, :preflight_timeout} =
             Preflight.runtime(path, :options, "6,192.0.2.1\n", tmpdir, 30)

    assert Path.wildcard(Path.join(tmpdir, ".dnsmasq-check-*")) == []
  end

  test "respects the resolver path while explicit servers remain authoritative", %{
    tmp_dir: tmpdir
  } do
    path = Path.join(tmpdir, "resolv.conf")
    config = Config.normalize(@base)
    raw = raw(config, tmpdir, resolvconf: path)
    assert elem(hd(raw.files), 1) =~ "resolv-file=#{path}\n"
    explicit = Config.normalize(%{@base | dnsmasq: %{name_servers: []}})
    text = elem(hd(raw(explicit, tmpdir, resolvconf: path).files), 1)
    assert text =~ "no-resolv\n"
    refute text =~ "resolv-file="
    assert Config.required_features(config) == []
    refute elem(hd(raw.files), 1) =~ "dhcp-script="

    assert_raise ArgumentError, fn -> raw(config, tmpdir, resolvconf: path <> "\nport=0") end
  end

  test "normalizes upstream ports, scopes and sources without allowing injected directives" do
    for endpoint <- [
          "127.0.0.1#5353",
          "fe80::1%eth0#5353",
          "192.0.2.1#5353@192.0.2.2#5300",
          "2001:db8::1@eth0@2001:db8::2#5300"
        ] do
      assert Upstream.normalize(endpoint) == endpoint
    end

    for endpoint <- [
          "127.0.0.1#65536",
          "127.0.0.1#x",
          "127.0.0.1@::1",
          "::1@eth0@eth1",
          "127.0.0.1\nport=0",
          "fe80::1%",
          "127.0.0.1@",
          <<255>>,
          "192.0.2.1@" <> <<255>>,
          "fe80::1%" <> <<255>>
        ] do
      assert_raise ArgumentError, fn -> Upstream.normalize(endpoint) end
    end
  end

  test "advanced options cannot take over supervision or inject another directive" do
    for key <- [
          :pid_file,
          :conf_file,
          :conf_script,
          :conf_dir,
          :dhcp_script,
          :leasefile_ro,
          :interface,
          :keep_in_foreground,
          :test,
          :typo
        ] do
      assert_raise ArgumentError, fn -> Directives.normalize([{key, "/tmp/override"}]) end
    end

    for {key, value} <- [
          cache_size: true,
          cache_size: -1,
          port: 65_536,
          port: "53",
          max_tcp_connections: 0,
          dhcp_host: "x\ny",
          server: "x\ry",
          dhcp_range: <<255>>,
          dhcp_host: <<255>>
        ] do
      assert_raise ArgumentError, fn -> Directives.normalize([{key, value}]) end
    end

    assert_raise ArgumentError, fn ->
      Config.normalize(%{@base | dnsmasq: %{port: 5353, directives: [port: 5354]}})
    end

    assert_raise ArgumentError, fn ->
      Config.normalize(%{@base | dnsmasq: %{upstreams: [cache_size: 10]}})
    end
  end

  test "native advertisement and stateless ranges cannot accept stateful reservations" do
    for range <- ["fd12::,ra-only,64", "tag:esp,fd12::,ra-stateless,64", "fd12::,ra-names,64"] do
      dnsmasq = %{directives: [dhcp_range: range]}
      assert IPv6.native_ranges?(dnsmasq)
      refute IPv6.dhcp_enabled?(dnsmasq)

      assert_raise ArgumentError, ~r/static leases need stateful/, fn ->
        Config.normalize(%{
          ipv6: %{method: :static, address: "fd12::1", prefix_length: 64},
          dnsmasq:
            Map.put(dnsmasq, :static_leases6, [%{duid: "00:03:00:01:02:03", ip: "fd12::100"}])
        })
      end
    end

    for range <- [
          "fd12::,static,64",
          "tag:esp,fd12::100,fd12::110,slaac,64",
          "::100,::110,constructor:eth1"
        ] do
      assert IPv6.dhcp_enabled?(%{directives: [dhcp_range: range]})
    end

    refute IPv6.native_ranges?(%{directives: [dhcp_range: "tag:esp,192.0.2.2,192.0.2.9"]})
  end

  test "relay and boot policies do not silently create a local IPv4 allocation pool", %{
    tmp_dir: tmpdir
  } do
    for directives <- [
          [dhcp_relay: "192.0.2.1,192.0.2.254"],
          [script_arp: true],
          [enable_tftp: true, dhcp_boot: "boot.img"],
          [dhcp_range: "192.0.2.0,proxy"]
        ] do
      config = Config.normalize(%{@base | dnsmasq: %{directives: directives}})
      refute Config.dhcp_enabled?(config.dnsmasq)
      assert Config.dhcp_services?(config.dnsmasq)
      refute elem(hd(raw(config, tmpdir).files), 1) =~ "dhcp-range="
    end

    config = Config.normalize(%{@base | dnsmasq: %{dhcp_hosts: ["id:01:02:03,192.0.2.100"]}})
    assert Config.dhcp_enabled?(config.dnsmasq)
    assert elem(hd(raw(config, tmpdir).files), 1) =~ "dhcp-range=192.0.2.0,static"
  end

  test "native RA ranges accept spaces and still require interface listening" do
    config = %{
      ipv6: %{method: :static, address: "fd12::1", prefix_length: 64},
      dnsmasq: %{directives: [dhcp_range: "fd12::, ra-only, 64"]}
    }

    assert Config.normalize(config).dnsmasq.listen_mode == :interface

    assert_raise ArgumentError, ~r/interface/, fn ->
      Config.normalize(put_in(config, [:dnsmasq, :listen_mode], :addresses))
    end
  end

  @tag :dnsmasq
  test "native range roles follow the system parser's comments and quoted tags", %{
    tmp_dir: tmpdir
  } do
    for {range, ra?, dhcp4?, dhcp6?} <- [
          {"fd12::,ra-only # comment", true, false, false},
          {"fd12::,static # comment", false, false, true},
          {"fd12::10,fd12::99 # comment", false, false, true},
          {"fd12::,ra-stateless # comment", true, false, false},
          {"192.0.2.0,proxy # comment", false, false, false},
          {~s(192.0.2.0,"proxy" # comment), false, false, false},
          {~s(192.0.2.0, "proxy"# comment), false, false, false},
          {~s(fd12::,"r"a-only # comment), true, false, false},
          {~s(fd12::,sta"t"ic # comment), false, false, true},
          {"192.0.2.10,192.0.2.99 # comment", false, true, false},
          {"tag:group#1,fd12::,ra-only # comment", true, false, false},
          {~s(tag:"group # 1",fd12::,ra-only # comment), true, false, false},
          {~s(tag:"group,192.0.2.10,proxy",fd12::,ra-only # comment), true, false, false},
          {~S(tag:"group\" # 1",fd12::,ra-only # "unfinished), true, false, false}
        ] do
      assert :ok = Preflight.runtime("dnsmasq", :directives, "dhcp-range=#{range}\n", tmpdir)

      config =
        Config.normalize(%{
          ipv4: @base.ipv4,
          ipv6: %{method: :static, address: "fd12::1", prefix_length: 64},
          dnsmasq: %{directives: [dhcp_range: range]}
        })

      assert IPv6.ra_enabled?(config.dnsmasq) == ra?, range
      assert Config.dhcp_enabled?(config.dnsmasq) == dhcp4?, range
      assert IPv6.dhcp_enabled?(config.dnsmasq) == dhcp6?, range

      assert config.dnsmasq.listen_mode ==
               if(ra? or dhcp4? or dhcp6?, do: :interface, else: :addresses),
             range

      assert Config.normalize(config) == config
    end
  end

  test "native pools determine IPv4 allocation even when reservation files exist" do
    config =
      Config.normalize(%{
        @base
        | dnsmasq: %{
            static_leases: [{"02:00:00:00:00:02", "192.0.2.100"}],
            directives: [dhcp_range: "192.0.2.0,proxy"]
          }
      })

    refute Config.dhcp_enabled?(config.dnsmasq)
  end

  test "IPv6 reservations cannot implicitly mix generated pools with native IPv4 pools" do
    assert_raise ArgumentError, ~r/static leases need stateful DHCPv6/, fn ->
      Config.normalize(%{
        ipv6: %{method: :static, address: "fd12::1", prefix_length: 64},
        dnsmasq: %{
          directives: [dhcp_range: "192.0.2.100,192.0.2.110"],
          static_leases6: [%{duid: "00:03:00:01:02:03", ip: "fd12::100"}]
        }
      })
    end
  end

  @tag :dnsmasq
  test "the system parser checks native policies, records, and boot configuration together", %{
    tmp_dir: tmpdir
  } do
    config =
      Config.normalize(%{
        @base
        | dnsmasq: %{
            port: 0,
            cache_size: 512,
            dhcp_lease_max: 100,
            name_servers: [],
            directives: [
              dhcp_range: "set:esp,192.0.2.100,192.0.2.110,255.255.255.0,600",
              dhcp_vendorclass: "set:esp,ESP",
              dhcp_option_force: "tag:esp,42,192.0.2.1",
              dhcp_ignore: "tag:!known",
              dhcp_rapid_commit: true,
              stop_dns_rebind: true,
              rebind_domain_ok: "/lan/",
              strict_order: true,
              local_ttl: 30,
              filter_aaaa: false,
              ptr_record: "1.2.0.192.in-addr.arpa,gateway.lan",
              caa_record: "lan,0,issue,ca.example",
              naptr_record: "lan,10,20,\"s\",\"SIP+D2U\",\"\",_sip._udp.lan",
              dhcp_boot: "boot.img",
              enable_tftp: true,
              tftp_root: tmpdir,
              pxe_service: "x86PC,\"Boot\",boot"
            ],
            dhcp_hosts: ["id:01:02:03,set:esp,192.0.2.100,esp32,600"],
            dhcp_options: ["tag:esp,option:dns-server,192.0.2.1"],
            upstreams: [server: "127.0.0.1#5353", rev_server: "192.0.2.0/24,127.0.0.1#5353"]
          }
      })

    assert Config.normalize(config) == config
    raw = raw(config, tmpdir)
    for {path, contents} <- raw.files, do: File.write!(path, contents)

    assert :ok =
             Preflight.check(
               "dnsmasq",
               Config.conf_path(tmpdir, "eth1"),
               Config.required_features(config),
               runtime_files(tmpdir)
             )

    # --test skips hostsfile contents unless the wrapper explicitly expands them.
    File.write!(Config.runtime_path(:dhcp_hosts, tmpdir, "eth1"), "id:01:02:03,[not-an-ip]\n")

    assert {:error, {:invalid_configuration, _}} =
             Preflight.check(
               "dnsmasq",
               Config.conf_path(tmpdir, "eth1"),
               Config.required_features(config),
               runtime_files(tmpdir)
             )
  end

  @tag :dnsmasq
  test "constructs multiple IPv6 prefixes and validates advanced RA parameters", %{
    tmp_dir: tmpdir
  } do
    config =
      Config.normalize(%{
        ipv6: %{method: :manual},
        dnsmasq: %{
          directives: [
            dhcp_range: "::100,::1ff,constructor:eth1,slaac,64,600",
            dhcp_range: "fd34::100,fd34::1ff,64,deprecated",
            ra_param: "eth1,high,30,1800",
            dhcp_duid: "1234,01:02:03:04"
          ]
        }
      })

    assert config.dnsmasq.listen_mode == :interface
    assert :ipv6 in Config.required_features(config)
    assert :dhcpv6 in Config.required_features(config)
    raw = raw(config, tmpdir)
    assert raw.up_cmds == []
    for {path, contents} <- raw.files, do: File.write!(path, contents)

    assert :ok =
             Preflight.check(
               "dnsmasq",
               Config.conf_path(tmpdir, "eth1"),
               Config.required_features(config),
               runtime_files(tmpdir)
             )
  end

  defp raw(config, tmpdir, opts \\ []) do
    Config.add_config(
      %RawConfig{
        ifname: "eth1",
        type: Dnsmasqex,
        source_config: config,
        required_ifnames: ["eth1"]
      },
      config,
      [tmpdir: tmpdir] ++ opts
    )
  end

  defp runtime_files(tmpdir),
    do: Enum.map(Config.runtime_options(), &{&1, Config.runtime_path(&1, tmpdir, "eth1")})
end
