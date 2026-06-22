# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule DnsmasqexTest do
  use ExUnit.Case

  alias VintageNet.Interface.RawConfig
  alias Dnsmasqex.Leases
  alias Dnsmasqex.Notifications
  alias Dnsmasqex.Server

  defmodule WiredTechnology do
    @moduledoc false
    @behaviour VintageNet.Technology

    alias VintageNet.IP.IPv4Config

    @impl VintageNet.Technology
    def normalize(config), do: IPv4Config.normalize(config)

    @impl VintageNet.Technology
    def to_raw_config(ifname, config, _opts) do
      %RawConfig{
        ifname: ifname,
        type: __MODULE__,
        source_config: config,
        required_ifnames: [ifname],
        up_cmds: [:wired_up]
      }
    end

    @impl VintageNet.Technology
    def ioctl(_ifname, _command, _args), do: {:error, :unsupported}

    @impl VintageNet.Technology
    def check_system(_opts), do: :ok
  end

  @config %{
    type: Dnsmasqex,
    technology: WiredTechnology,
    ipv4: %{method: :static, address: "192.168.24.1", prefix_length: 24},
    dnsmasq: %{
      start: "192.168.24.10",
      end: "192.168.24.99",
      lease_time: 3600,
      static_leases: [
        {"aa:bb:cc:dd:ee:ff", "192.168.24.100"},
        {"aa:bb:cc:dd:ee:01", "192.168.24.101", "printer"}
      ],
      records: [{"device.example.com", "192.168.24.1"}],
      options: %{43 => "4d:53", router: [], dns: "192.168.24.1", search: ["lan"], mtu: 1400},
      hosts_dir: "/data/dnsmasq/hosts"
    }
  }

  defp raw_config(config),
    do: Dnsmasqex.to_raw_config("eth1", config, tmpdir: "/tmp/vintage_net")

  defp dnsmasq_conf(config) do
    [{"/tmp/vintage_net/dnsmasq.conf.eth1", contents} | _] = raw_config(config).files
    contents
  end

  test "keeps the wrapped technology's config and adds dnsmasq" do
    raw_config = raw_config(@config)

    assert raw_config.type == Dnsmasqex
    assert raw_config.up_cmds == [:wired_up]
    assert raw_config.source_config.technology == WiredTechnology
    assert raw_config.down_cmds == [{:fun, Notifications, :clear, ["eth1"]}]

    assert raw_config.cleanup_files == [
             "/tmp/vintage_net/dnsmasq.eth1.pid",
             "/tmp/vintage_net/dnsmasq.eth1.hosts.new",
             "/tmp/vintage_net/dnsmasq.eth1.options.new",
             "/tmp/vintage_net/dnsmasq.eth1.records.new"
           ]

    assert [
             {"/tmp/vintage_net/dnsmasq.conf.eth1", contents},
             {"/tmp/vintage_net/dnsmasq.eth1.hosts", hosts},
             {"/tmp/vintage_net/dnsmasq.eth1.options", options},
             {"/tmp/vintage_net/dnsmasq.eth1.records", records}
           ] = raw_config.files

    assert contents == """
           interface=eth1
           except-interface=lo
           listen-address=192.168.24.1
           bind-interfaces
           no-hosts
           user=root
           pid-file=/tmp/vintage_net/dnsmasq.eth1.pid
           dhcp-leasefile=/tmp/vintage_net/dnsmasq.eth1.leases
           dhcp-script=#{BEAMNotify.bin_path()}
           script-arp
           script-on-renewal
           dhcp-range=192.168.24.10,192.168.24.99,3600
           dhcp-hostsfile=/tmp/vintage_net/dnsmasq.eth1.hosts
           dhcp-optsfile=/tmp/vintage_net/dnsmasq.eth1.options
           dhcp-hostsdir=/data/dnsmasq/hosts
           addn-hosts=/tmp/vintage_net/dnsmasq.eth1.records
           """

    assert hosts == """
           aa:bb:cc:dd:ee:ff,192.168.24.100,infinite
           aa:bb:cc:dd:ee:01,192.168.24.101,printer,infinite
           """

    assert options == """
           43,4d:53
           option:dns-server,192.168.24.1
           option:mtu,1400
           option:router
           option:domain-search,lan
           """

    assert records == "192.168.24.1 device.example.com\n"
  end

  test "normalizing twice gives the same config" do
    dnsmasq =
      Map.merge(@config.dnsmasq, %{
        static_leases: [
          {"AA:BB:CC:DD:EE:FF", "192.168.24.100"},
          %{mac: "aa:bb:cc:dd:ee:01", ip: "192.168.24.101", lease_time: 600},
          %{mac: "aa:bb:cc:dd:ee:02", ignore: true}
        ],
        options: %{netmask: "255.255.255.0", serverid: "192.168.24.1", dns: "192.168.24.1"},
        name_servers: "1.1.1.1",
        forward_domains: [{"*.corp.example.com", "10.0.0.53"}],
        domain: "lan",
        domain_records: [{"#", "192.168.24.1"}],
        cnames: [{"www.lan", "pi.lan"}],
        srv_records: [{"_http._tcp.lan", "pi.lan", 80}],
        txt_records: [{"pi.lan", "v=1"}],
        mx_records: [{"lan", "pi.lan", 10}],
        nftsets: [{"example.com", "inet#filter#allowed"}],
        authoritative: true,
        lease_path: "/data/dnsmasq/eth1.leases"
      })

    for config <- [@config, %{@config | dnsmasq: dnsmasq}] do
      normalized = Dnsmasqex.normalize(config)
      assert Dnsmasqex.normalize(normalized) == normalized
    end
  end

  test "serves only DNS without a range or static leases" do
    contents =
      dnsmasq_conf(%{@config | dnsmasq: %{records: [{"device.example.com", "192.168.24.1"}]}})

    refute contents =~ "dhcp-range"
    assert contents =~ "addn-hosts="
  end

  test "serves only static leases without a range" do
    contents =
      dnsmasq_conf(%{
        @config
        | dnsmasq: %{static_leases: [{"aa:bb:cc:dd:ee:ff", "192.168.24.100"}]}
      })

    assert contents =~ "dhcp-range=192.168.24.0,static\n"
  end

  test "follows /etc/resolv.conf unless name servers are set" do
    refute dnsmasq_conf(@config) =~ "resolv"

    contents =
      dnsmasq_conf(%{
        @config
        | dnsmasq: %{
            name_servers: ["1.1.1.1", "2606:4700:4700::1111"],
            forward_domains: [
              {"corp.example.com", ["10.0.0.53", "10.0.0.54"]},
              {"lan", []}
            ]
          }
      })

    assert contents =~ """
           no-hosts
           no-resolv
           server=1.1.1.1
           server=2606:4700:4700::1111
           server=/corp.example.com/10.0.0.53
           server=/corp.example.com/10.0.0.54
           server=/lan/
           """

    assert dnsmasq_conf(%{@config | dnsmasq: %{name_servers: []}}) =~ "no-hosts\nno-resolv\n"
  end

  test "answers the local domain without forwarding it" do
    assert dnsmasq_conf(%{@config | dnsmasq: %{domain: "lan"}}) =~ """
           domain=lan
           local=/lan/
           expand-hosts
           """

    assert_raise ArgumentError, fn ->
      Dnsmasqex.normalize(%{@config | dnsmasq: %{domain: "lan\nconf-file=/tmp/x"}})
    end
  end

  test "writes every kind of DNS record" do
    contents =
      dnsmasq_conf(%{
        @config
        | dnsmasq: %{
            domain_records: [{"example.com", "192.168.24.2"}, {"#", "192.168.24.1"}],
            cnames: [{"www.lan", "pi.lan"}],
            srv_records: [
              {"_http._tcp.lan", "pi.lan", 80},
              {"_ipp._tcp.lan", "printer.lan", 631, 10, 5}
            ],
            txt_records: [{"pi.lan", ["v=1", ~s(say "hi" \\ bye)]}],
            mx_records: [{"lan", "mail.lan"}, {"example.com", "mail.lan", 10}]
          }
      })

    assert contents =~ """
           address=/example.com/192.168.24.2
           address=/#/192.168.24.1
           cname=www.lan,pi.lan
           srv-host=_http._tcp.lan,pi.lan,80
           srv-host=_ipp._tcp.lan,printer.lan,631,10,5
           txt-record=pi.lan,"v=1","say \\"hi\\" \\\\ bye"
           mx-host=lan,mail.lan
           mx-host=example.com,mail.lan,10
           """
  end

  test "keeps leases where configured and answers unknown leases when authoritative" do
    dnsmasq =
      Map.merge(@config.dnsmasq, %{authoritative: true, lease_path: "/data/dnsmasq/eth1.leases"})

    raw_config = raw_config(%{@config | dnsmasq: dnsmasq})
    [{_path, contents} | _] = raw_config.files

    assert contents =~ "dhcp-leasefile=/data/dnsmasq/eth1.leases\n"
    assert contents =~ "script-on-renewal\ndhcp-authoritative\n"
    assert raw_config.up_cmds == [:wired_up, {:fun, File, :mkdir_p, ["/data/dnsmasq"]}]

    refute dnsmasq_conf(@config) =~ "dhcp-authoritative"

    for dnsmasq <- [%{authoritative: "yes"}, %{lease_path: "leases"}, %{lease_path: "/data/a\nb"}] do
      assert_raise ArgumentError, fn ->
        Dnsmasqex.normalize(%{@config | dnsmasq: dnsmasq})
      end
    end
  end

  test "adds resolved addresses to nftables sets" do
    contents =
      dnsmasq_conf(%{
        @config
        | dnsmasq: %{
            nftsets: [
              {["example.com", "*.example.org"],
               ["inet#filter#allowed", "6#ip6#filter#allowed6"]},
              {"example.net", "filter#allowed"}
            ]
          }
      })

    assert contents =~ """
           nftset=/example.com/*.example.org/inet#filter#allowed,6#ip6#filter#allowed6
           nftset=/example.net/filter#allowed
           """

    for nftset <- [
          {[], ["inet#filter#allowed"]},
          {["example.com"], []},
          {["example.com"], ["allowed"]},
          {["example.com"], ["inet#filter#allowed,other"]},
          {["bad domain"], ["filter#allowed"]},
          "example.com"
        ] do
      assert_raise ArgumentError, fn ->
        Dnsmasqex.normalize(%{@config | dnsmasq: %{nftsets: [nftset]}})
      end
    end
  end

  test "supports infinite leases" do
    contents = dnsmasq_conf(put_in(@config, [:dnsmasq, :lease_time], :infinite))
    assert contents =~ "dhcp-range=192.168.24.10,192.168.24.99,infinite\n"
  end

  test "drops dnsmasq when the interface isn't static" do
    raw_config = raw_config(%{@config | ipv4: %{method: :dhcp}})

    assert raw_config.files == []
    assert raw_config.child_specs == []
    refute Map.has_key?(raw_config.source_config, :dnsmasq)
  end

  test "rejects options dnsmasq would misread or ignore" do
    for dnsmasq <- [
          %{start: "192.168.24.10"},
          %{end: "192.168.24.99"},
          %{start: "192.168.24.99", end: "192.168.24.10"},
          %{start: "192.168.25.10", end: "192.168.25.99"},
          %{start: "fd00::10", end: "fd00::99"},
          %{lease_time: 60},
          %{lease_time: "1h"},
          %{static_leases: [{"aa:bb:cc:dd:ee", "192.168.24.100"}]},
          %{static_leases: [{"aa:bb:cc:dd:ee:ff", "192.168.25.100"}]},
          %{static_leases: [{"aa:bb:cc:dd:ee:ff", "192.168.24.100", "bad host"}]},
          %{static_leases: [{"aa:bb:cc:dd:ee:ff", "192.168.24.100", "ignore"}]},
          %{static_leases: [{"aa:bb:cc:dd:ee:ff", "192.168.24.100", "3600"}]},
          %{static_leases: [:not_a_lease]},
          %{records: [{"a b.example.com", "192.168.24.1"}]},
          %{records: [{"device.example.com\naddress=/x/1.2.3.4", "192.168.24.1"}]},
          %{hosts_dir: "relative/hosts"},
          %{hosts_dir: "/data\ndhcp-script=/tmp/x"}
        ] do
      assert_raise ArgumentError, fn ->
        Dnsmasqex.normalize(%{@config | dnsmasq: dnsmasq})
      end
    end
  end

  test "rejects configs that can't work" do
    for config <- [
          Map.put(@config, :dhcpd, %{start: "192.168.24.10", end: "192.168.24.99"}),
          Map.put(@config, :dnsd, %{records: []}),
          Map.delete(@config, :technology),
          %{@config | technology: Dnsmasqex}
        ] do
      assert_raise ArgumentError, fn -> Dnsmasqex.normalize(config) end
    end
  end

  describe "runtime ioctls" do
    @hosts """
    aa:bb:cc:dd:ee:ff,192.168.24.100,infinite
    aa:bb:cc:dd:ee:01,192.168.24.101,printer,infinite
    """

    setup do
      tmpdir = Application.fetch_env!(:vintage_net, :tmpdir)
      File.mkdir_p!(tmpdir)

      paths =
        for name <- ~w(hosts options records pid), do: Path.join(tmpdir, "dnsmasq.ioctl0.#{name}")

      on_exit(fn ->
        PropertyTable.delete_matches(VintageNet, ["interface", "ioctl0"])
        Enum.each(paths ++ Enum.map(paths, &(&1 <> ".new")), &File.rm_rf!/1)
      end)

      [hosts_path, options_path, records_path, _pid_path] = paths

      %{
        server: start_server(@config),
        hosts_path: hosts_path,
        options_path: options_path,
        records_path: records_path,
        conf_path: Path.join(tmpdir, "dnsmasq.conf.ioctl0")
      }
    end

    defp start_server(config) do
      config = Dnsmasqex.normalize(config)
      PropertyTable.put(VintageNet, ["interface", "ioctl0", "config"], config)
      tmpdir = Application.fetch_env!(:vintage_net, :tmpdir)
      start_supervised!({Server, ifname: "ioctl0", tmpdir: tmpdir, config: config})
    end

    defp ioctl(command, args), do: Dnsmasqex.ioctl("ioctl0", command, args)
    defp runtime(option), do: VintageNet.get(["interface", "ioctl0", "dnsmasq", option])

    test "publishes and writes the configured values", context do
      assert File.read!(context.hosts_path) == @hosts
      assert File.read!(context.records_path) == "192.168.24.1 device.example.com\n"

      assert runtime("static_leases") ==
               Dnsmasqex.normalize(@config).dnsmasq.static_leases

      assert runtime("records") == [{"device.example.com", {192, 168, 24, 1}}]
      assert %{router: [], mtu: 1400} = runtime("options")
    end

    test "keeps the current values when a change is invalid", context do
      assert {:error, "Invalid MAC address \"not-a-mac\""} =
               ioctl(:static_leases, [[{"not-a-mac", "192.168.24.100"}]])

      assert {:error, "Expected a list for :static_leases, got: nil"} =
               ioctl(:static_leases, [nil])

      assert {:error, "Invalid dnsmasq option {:mtu, 1}"} = ioctl(:options, [%{mtu: 1}])
      assert {:error, "Invalid dnsmasq ioctl :add_static_lease []"} = ioctl(:add_static_lease, [])

      for command <- [:add_record, :put_record], ips <- [nil, []] do
        assert {:error, _} = ioctl(command, [{"device.example.com", ips}])
      end

      assert File.read!(context.hosts_path) == @hosts
      assert File.read!(context.records_path) == "192.168.24.1 device.example.com\n"
      assert %{mtu: 1400} = runtime("options")
    end

    test "applies changes while dnsmasq isn't running", context do
      assert :ok = ioctl(:static_leases, [[{"aa:bb:cc:dd:ee:02", "192.168.24.102"}]])
      assert File.read!(context.hosts_path) == "aa:bb:cc:dd:ee:02,192.168.24.102,infinite\n"
      assert runtime("static_leases") == [{"aa:bb:cc:dd:ee:02", {192, 168, 24, 102}}]
    end

    test "adds static leases one at a time and refuses to take a MAC or address", context do
      assert :ok = ioctl(:add_static_lease, [{"aa:bb:cc:dd:ee:02", "192.168.24.102", "esp32"}])
      assert :ok = ioctl(:add_static_lease, [%{mac: "aa:bb:cc:dd:ee:03", hostname: "camera"}])

      assert File.read!(context.hosts_path) ==
               @hosts <>
                 "aa:bb:cc:dd:ee:02,192.168.24.102,esp32,infinite\naa:bb:cc:dd:ee:03,camera\n"

      assert ioctl(:add_static_lease, [{"AA:BB:CC:DD:EE:FF", "192.168.24.110"}]) ==
               {:error, {:mac_in_use, {"aa:bb:cc:dd:ee:ff", {192, 168, 24, 100}}}}

      assert ioctl(:add_static_lease, [{"aa:bb:cc:dd:ee:04", "192.168.24.101"}]) ==
               {:error, {:ip_in_use, {"aa:bb:cc:dd:ee:01", {192, 168, 24, 101}, "printer"}}}
    end

    test "puts a static lease in place of the one with the same MAC", context do
      assert :ok = ioctl(:put_static_lease, [{"aa:bb:cc:dd:ee:ff", "192.168.24.110", "esp32"}])
      assert :ok = ioctl(:put_static_lease, [%{mac: "aa:bb:cc:dd:ee:05", ignore: true}])

      assert File.read!(context.hosts_path) == """
             aa:bb:cc:dd:ee:01,192.168.24.101,printer,infinite
             aa:bb:cc:dd:ee:ff,192.168.24.110,esp32,infinite
             aa:bb:cc:dd:ee:05,ignore
             """

      assert ioctl(:put_static_lease, [{"aa:bb:cc:dd:ee:ff", "192.168.24.101"}]) ==
               {:error, {:ip_in_use, {"aa:bb:cc:dd:ee:01", {192, 168, 24, 101}, "printer"}}}
    end

    test "removes static leases by MAC", context do
      assert :ok = ioctl(:remove_static_lease, ["AA:BB:CC:DD:EE:FF"])
      assert :ok = ioctl(:remove_static_lease, ["aa:bb:cc:dd:ee:99"])

      assert File.read!(context.hosts_path) ==
               "aa:bb:cc:dd:ee:01,192.168.24.101,printer,infinite\n"
    end

    test "applies concurrent changes one after another", context do
      1..8
      |> Task.async_stream(
        &ioctl(:add_static_lease, [{"aa:bb:cc:dd:e0:0#{&1}", {192, 168, 24, 110 + &1}}])
      )
      |> Enum.each(&assert(&1 == {:ok, :ok}))

      assert length(String.split(File.read!(context.hosts_path), "\n", trim: true)) == 10
    end

    test "rejects lease changes without DHCP" do
      stop_supervised!(Server)
      start_server(%{@config | dnsmasq: %{}})

      for {command, args} <- [
            static_leases: [[{"aa:bb:cc:dd:ee:ff", "192.168.24.100"}]],
            add_static_lease: [{"aa:bb:cc:dd:ee:ff", "192.168.24.100"}],
            put_static_lease: [{"aa:bb:cc:dd:ee:ff", "192.168.24.100"}],
            remove_static_lease: ["aa:bb:cc:dd:ee:ff"]
          ] do
        assert ioctl(command, args) == {:error, :dhcp_disabled}
      end

      assert :ok = ioctl(:add_record, [{"pi.lan", "192.168.24.1"}])
    end

    test "adds, puts and removes records by name", context do
      assert :ok = ioctl(:add_record, [{"pi.lan", ["192.168.24.1", "fd00::1"]}])

      assert ioctl(:add_record, [{"PI.LAN", "192.168.24.2"}]) ==
               {:error,
                {:name_in_use,
                 [{"pi.lan", {192, 168, 24, 1}}, {"pi.lan", {64_768, 0, 0, 0, 0, 0, 0, 1}}]}}

      assert :ok = ioctl(:put_record, [{"Device.Example.Com", "192.168.24.3"}])
      assert :ok = ioctl(:remove_record, ["Pi.Lan"])
      assert File.read!(context.records_path) == "192.168.24.3 Device.Example.Com\n"
      assert {:error, _} = ioctl(:put_record, [{"bad name", "192.168.24.3"}])
    end

    test "puts and deletes DHCP options", context do
      assert :ok = ioctl(:put_option, [:ntp, "192.168.24.1"])
      assert :ok = ioctl(:put_option, [:netmask, "255.255.255.0"])
      assert %{ntp: [{192, 168, 24, 1}], subnet: {255, 255, 255, 0}} = runtime("options")

      assert :ok = ioctl(:delete_option, [:netmask])
      assert :ok = ioctl(:delete_option, [43])
      refute Map.has_key?(runtime("options"), :subnet)
      refute File.read!(context.options_path) =~ "43,"
      assert File.read!(context.options_path) =~ "option:ntp-server,192.168.24.1\n"
    end

    test "returns file errors without changing the current values", context do
      File.mkdir!(context.hosts_path <> ".new")
      assert {:error, :eisdir} = ioctl(:static_leases, [[]])
      assert File.read!(context.hosts_path) == @hosts
      assert length(runtime("static_leases")) == 2
    end

    test "restores the configured values if it restarts", context do
      assert :ok = ioctl(:remove_static_lease, ["aa:bb:cc:dd:ee:ff"])
      VintageNet.subscribe(["interface", "ioctl0", "dnsmasq", "static_leases"])
      ref = Process.monitor(context.server)
      Process.exit(context.server, :kill)

      assert_receive {:DOWN, ^ref, :process, _, :killed}
      assert_receive {VintageNet, _, [_], [_, _], _}
      assert File.read!(context.hosts_path) == @hosts
    end

    @tag :linux
    test "signals dnsmasq to reload each kind of change", context do
      port = start_process("trap 'echo reloaded' HUP", context.conf_path)

      for {command, args} <- [
            static_leases: [[{"aa:bb:cc:dd:ee:01", "192.168.24.101", "printer"}]],
            add_static_lease: [{"aa:bb:cc:dd:ee:02", "192.168.24.102"}],
            options: [%{router: []}],
            put_option: [:ntp, "192.168.24.1"],
            records: [[{"pi.lan", "192.168.24.1"}]],
            remove_record: ["pi.lan"]
          ] do
        assert :ok = ioctl(command, args)
        assert_receive {^port, {:data, "reloaded\n"}}, 3000
      end

      refute File.exists?(context.hosts_path <> ".new")
    end

    @tag :linux
    test "doesn't match another interface's configuration path", context do
      start_process(":", context.conf_path <> "0")
      assert {:error, :not_running} = ioctl(:reload, [])
    end

    @tag :linux
    test "requires the configuration path to follow the configuration option", context do
      start_process(":", context.conf_path, "--unrelated")
      assert {:error, :not_running} = ioctl(:reload, [])
    end

    @tag :linux
    test "doesn't signal a process that reused a stale pid" do
      port = start_process("trap 'echo alive' USR1", "unrelated")
      {:os_pid, os_pid} = Port.info(port, :os_pid)

      assert {:error, :not_running} = ioctl(:reload, [])

      System.cmd("kill", ["-USR1", to_string(os_pid)])
      assert_receive {^port, {:data, "alive\n"}}, 3000
    end

    defp start_process(traps, name, option \\ "-C") do
      script = "trap 'exit' TERM; #{traps}; echo ready; while true; do sleep 1 & wait $!; done"

      port =
        Port.open({:spawn_executable, "/bin/sh"}, [
          :binary,
          args: ["-c", script, "dnsmasq-test", option, name]
        ])

      {:os_pid, os_pid} = Port.info(port, :os_pid)
      pid_path = Path.join(Application.fetch_env!(:vintage_net, :tmpdir), "dnsmasq.ioctl0.pid")
      File.write!(pid_path, "#{os_pid}\n")
      on_exit(fn -> System.cmd("kill", [to_string(os_pid)], stderr_to_stdout: true) end)
      assert_receive {^port, {:data, "ready\n"}}, 3000
      port
    end
  end

  describe "capabilities" do
    @moduletag :tmp_dir

    @version """
    Dnsmasq version 2.91  Copyright (c) 2000-2025 Simon Kelley
    Compile time options: IPv6 GNU-getopt no-DBus no-UBus no-i18n no-IDN DHCP DHCPv6 no-Lua TFTP no-conntrack ipset no-nftset auth no-DNSSEC loop-detect inotify dumpfile

    This software comes with ABSOLUTELY NO WARRANTY.
    """

    defp fake_dnsmasq(tmp_dir, output, status \\ 0) do
      path = Path.join(tmp_dir, "dnsmasq")
      File.write!(path, "#!/bin/sh\ncat <<'EOF'\n#{output}EOF\nexit #{status}\n")
      File.chmod!(path, 0o755)
      Application.put_env(:dnsmasqex, :dnsmasq, path)
      on_exit(fn -> Application.delete_env(:dnsmasqex, :dnsmasq) end)
    end

    test "reports the version and features dnsmasq was built with", %{tmp_dir: tmp_dir} do
      fake_dnsmasq(tmp_dir, @version)

      assert Dnsmasqex.capabilities() ==
               {:ok,
                %{
                  version: "2.91",
                  ipv6: true,
                  dhcp: true,
                  dhcpv6: true,
                  scripts: true,
                  lua: false,
                  tftp: true,
                  auth: true,
                  dnssec: false,
                  ipset: true,
                  nftset: false,
                  conntrack: false,
                  dbus: false,
                  ubus: false,
                  i18n: false,
                  idn: false,
                  loop_detect: true,
                  inotify: true,
                  dumpfile: true
                }}

      assert Dnsmasqex.check_system([]) == :ok
    end

    test "rejects a dnsmasq that can't serve DHCP or run the event script", %{tmp_dir: tmp_dir} do
      for options <- ["IPv6 no-DHCP no-scripts", "IPv6 DHCP no-DHCPv6 no-scripts", "IPv6 no-DHCP"] do
        fake_dnsmasq(tmp_dir, "Dnsmasq version 2.91\nCompile time options: #{options}\n")

        assert Dnsmasqex.check_system([]) ==
                 {:error, "#{tmp_dir}/dnsmasq was built without DHCP or script support"}
      end
    end

    test "requests untranslated version output", %{tmp_dir: tmp_dir} do
      locale = System.get_env("LC_ALL")
      System.put_env("LC_ALL", "fr_FR.UTF-8")

      on_exit(fn ->
        if locale, do: System.put_env("LC_ALL", locale), else: System.delete_env("LC_ALL")
      end)

      path = Path.join(tmp_dir, "dnsmasq")

      File.write!(path, """
      #!/bin/sh
      if [ "$LC_ALL" = C ]; then
        echo 'Dnsmasq version 2.91'
        echo 'Compile time options: DHCP'
      else
        echo 'Options de compilation: DHCP'
      fi
      """)

      File.chmod!(path, 0o755)
      Application.put_env(:dnsmasqex, :dnsmasq, path)
      on_exit(fn -> Application.delete_env(:dnsmasqex, :dnsmasq) end)

      assert {:ok, %{version: "2.91", dhcp: true}} = Dnsmasqex.capabilities()
    end

    test "reports dnsmasq failures", %{tmp_dir: tmp_dir} do
      fake_dnsmasq(tmp_dir, "broken\n", 1)
      assert Dnsmasqex.capabilities() == {:error, "broken"}

      fake_dnsmasq(tmp_dir, "something else\n")

      assert {:error, "Unexpected dnsmasq --version output" <> _} =
               Dnsmasqex.capabilities()
    end

    test "finds nf_tables loaded, built in, or as a module", %{tmp_dir: tmp_dir} do
      modules = Path.join(tmp_dir, "lib/modules/6.18.33-v8")
      File.mkdir_p!(modules)
      File.mkdir_p!(Path.join(tmp_dir, "proc/sys/kernel"))
      File.write!(Path.join(tmp_dir, "proc/sys/kernel/osrelease"), "6.18.33-v8\n")
      File.write!(Path.join(modules, "modules.dep"), "kernel/net/netfilter/nf_tables_set.ko:\n")
      refute Dnsmasqex.nftables_available?(tmp_dir)

      File.write!(Path.join(modules, "modules.builtin"), "kernel/net/netfilter/nf_tables.ko\n")
      assert Dnsmasqex.nftables_available?(tmp_dir)

      File.rm!(Path.join(modules, "modules.builtin"))

      File.write!(
        Path.join(modules, "modules.dep"),
        "kernel/net/netfilter/nf_tables.ko.xz: x.ko\n"
      )

      assert Dnsmasqex.nftables_available?(tmp_dir)

      File.rm_rf!(Path.join(tmp_dir, "lib"))
      refute Dnsmasqex.nftables_available?(tmp_dir)
      File.mkdir_p!(Path.join(tmp_dir, "sys/module/nf_tables"))
      assert Dnsmasqex.nftables_available?(tmp_dir)
    end
  end

  test "check_system looks for dnsmasq" do
    Application.put_env(:dnsmasqex, :dnsmasq, "/nonexistent/dnsmasq")
    on_exit(fn -> Application.delete_env(:dnsmasqex, :dnsmasq) end)

    assert Dnsmasqex.check_system([]) == {:error, "Can't find /nonexistent/dnsmasq"}
  end

  test "parses dnsmasq leases and skips malformed lines" do
    contents = """
    0 aa:bb:cc:dd:ee:ff 192.168.24.100 printer *
    1100 aa:bb:cc:dd:ee:01 192.168.24.10 * 01:aa:bb:cc:dd:ee:01
    never aa:bb:cc:dd:ee:02 192.168.24.11 host *
    """

    assert Leases.parse(contents, 1000) == [
             %{
               leasetime: :infinity,
               lease_nip: "192.168.24.100",
               lease_mac: "aa:bb:cc:dd:ee:ff",
               hostname: "printer"
             },
             %{
               leasetime: 100,
               lease_nip: "192.168.24.10",
               lease_mac: "aa:bb:cc:dd:ee:01",
               hostname: ""
             }
           ]
  end
end
