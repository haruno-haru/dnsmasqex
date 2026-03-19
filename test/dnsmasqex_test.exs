# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule DnsmasqexTest do
  use ExUnit.Case

  alias VintageNet.Interface.RawConfig
  alias Dnsmasqex.Leases
  alias Dnsmasqex.Notifications

  defmodule WiredTechnology do
    @moduledoc false
    @behaviour VintageNet.Technology

    @impl VintageNet.Technology
    def normalize(config), do: config

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
      hosts_dir: "/data/dnsmasq/hosts"
    }
  }

  test "keeps the wrapped technology's config and adds dnsmasq" do
    raw_config = Dnsmasqex.to_raw_config("eth1", @config, tmpdir: "/tmp/vintage_net")

    assert raw_config.type == Dnsmasqex
    assert raw_config.up_cmds == [:wired_up]
    assert raw_config.source_config.technology == WiredTechnology
    assert raw_config.down_cmds == [{:fun, Notifications, :clear, ["eth1"]}]

    assert [
             {"/tmp/vintage_net/dnsmasq.conf.eth1", contents},
             {"/tmp/vintage_net/dnsmasq.eth1.hosts", hosts}
           ] = raw_config.files

    assert hosts == """
           aa:bb:cc:dd:ee:ff,192.168.24.100,infinite
           aa:bb:cc:dd:ee:01,192.168.24.101,printer,infinite
           """

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
           dhcp-hostsdir=/data/dnsmasq/hosts
           address=/device.example.com/192.168.24.1
           """
  end

  test "serves only DNS without a DHCP range" do
    config = %{@config | dnsmasq: %{records: [{"device.example.com", "192.168.24.1"}]}}
    raw_config = Dnsmasqex.to_raw_config("eth1", config, tmpdir: "/tmp/vintage_net")

    [{_path, contents}, _hosts] = raw_config.files
    refute contents =~ "dhcp-range"
    assert contents =~ "address=/device.example.com/192.168.24.1"
  end

  test "supports infinite leases" do
    config = put_in(@config, [:dnsmasq, :lease_time], :infinite)
    raw_config = Dnsmasqex.to_raw_config("eth1", config, tmpdir: "/tmp/vintage_net")

    [{_path, contents}, _hosts] = raw_config.files
    assert contents =~ "dhcp-range=192.168.24.10,192.168.24.99,infinite\n"
  end

  test "drops dnsmasq when the interface isn't static" do
    config = %{@config | ipv4: %{method: :dhcp}}
    raw_config = Dnsmasqex.to_raw_config("eth1", config, tmpdir: "/tmp/vintage_net")

    assert raw_config.files == []
    assert raw_config.child_specs == []
    refute Map.has_key?(raw_config.source_config, :dnsmasq)
  end

  test "rejects invalid options" do
    for dnsmasq <- [
          %{start: "192.168.24.10"},
          %{end: "192.168.24.99"},
          %{lease_time: 0},
          %{lease_time: "1h"},
          %{static_leases: [{"aa:bb:cc:dd:ee", "192.168.24.100"}]},
          %{records: [{"a b.example.com", "192.168.24.1"}]},
          %{records: [{"device.example.com\naddress=/x/1.2.3.4", "192.168.24.1"}]},
          %{static_leases: [{"aa:bb:cc:dd:ee:ff", "192.168.24.100", "bad host"}]},
          %{hosts_dir: :data}
        ] do
      assert_raise ArgumentError, fn ->
        Dnsmasqex.normalize(%{@config | dnsmasq: dnsmasq})
      end
    end
  end

  describe "static_leases ioctl" do
    setup do
      tmpdir = Application.fetch_env!(:vintage_net, :tmpdir)
      File.mkdir_p!(tmpdir)
      hosts_path = Path.join(tmpdir, "dnsmasq.ioctl0.hosts")
      pid_path = Path.join(tmpdir, "dnsmasq.ioctl0.pid")
      on_exit(fn -> Enum.each([hosts_path, pid_path], &File.rm/1) end)
      %{hosts_path: hosts_path, pid_path: pid_path}
    end

    test "keeps the current leases when a lease is invalid", %{hosts_path: hosts_path} do
      File.write!(hosts_path, "aa:bb:cc:dd:ee:ff,192.168.24.100,infinite\n")

      assert {:error, "Invalid MAC address \"not-a-mac\""} =
               Dnsmasqex.ioctl("ioctl0", :static_leases, [
                 [{"not-a-mac", "192.168.24.100"}]
               ])

      assert File.read!(hosts_path) == "aa:bb:cc:dd:ee:ff,192.168.24.100,infinite\n"
    end

    test "rewrites the leases and signals dnsmasq to reload", context do
      port =
        Port.open({:spawn_executable, "/bin/sh"}, [
          :binary,
          args: ["-c", "trap 'echo reloaded' HUP; while true; do sleep 1; done"]
        ])

      {:os_pid, os_pid} = Port.info(port, :os_pid)
      File.write!(context.pid_path, "#{os_pid}\n")
      on_exit(fn -> System.cmd("kill", [to_string(os_pid)]) end)

      assert :ok =
               Dnsmasqex.ioctl("ioctl0", :static_leases, [
                 [{"aa:bb:cc:dd:ee:01", "192.168.24.101", "printer"}]
               ])

      assert File.read!(context.hosts_path) ==
               "aa:bb:cc:dd:ee:01,192.168.24.101,printer,infinite\n"

      assert_receive {^port, {:data, "reloaded\n"}}, 3000
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
