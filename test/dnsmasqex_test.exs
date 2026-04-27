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
             "/tmp/vintage_net/dnsmasq.eth1.hosts.new"
           ]

    assert [
             {"/tmp/vintage_net/dnsmasq.conf.eth1", contents},
             {"/tmp/vintage_net/dnsmasq.eth1.hosts", hosts}
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
           dhcp-hostsdir=/data/dnsmasq/hosts
           address=/device.example.com/192.168.24.1
           """

    assert hosts == """
           aa:bb:cc:dd:ee:ff,192.168.24.100,infinite
           aa:bb:cc:dd:ee:01,192.168.24.101,printer,infinite
           """
  end

  test "normalizing twice gives the same config" do
    normalized = Dnsmasqex.normalize(@config)
    assert Dnsmasqex.normalize(normalized) == normalized
  end

  test "serves only DNS without a range or static leases" do
    contents =
      dnsmasq_conf(%{@config | dnsmasq: %{records: [{"device.example.com", "192.168.24.1"}]}})

    refute contents =~ "dhcp-range"
    assert contents =~ "address=/device.example.com/192.168.24.1"
  end

  test "serves only static leases without a range" do
    contents =
      dnsmasq_conf(%{
        @config
        | dnsmasq: %{static_leases: [{"aa:bb:cc:dd:ee:ff", "192.168.24.100"}]}
      })

    assert contents =~ "dhcp-range=192.168.24.0,static\n"
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

  describe "static_leases ioctl" do
    setup do
      dnsmasq = Application.fetch_env(:dnsmasqex, :dnsmasq)
      Application.put_env(:dnsmasqex, :dnsmasq, "/bin/sh")
      tmpdir = Application.fetch_env!(:vintage_net, :tmpdir)
      File.mkdir_p!(tmpdir)
      hosts_path = Path.join(tmpdir, "dnsmasq.ioctl0.hosts")
      pid_path = Path.join(tmpdir, "dnsmasq.ioctl0.pid")
      File.write!(hosts_path, "aa:bb:cc:dd:ee:ff,192.168.24.100,infinite\n")

      config_property = ["interface", "ioctl0", "config"]
      PropertyTable.put(VintageNet, config_property, Dnsmasqex.normalize(@config))

      on_exit(fn ->
        case dnsmasq do
          {:ok, value} -> Application.put_env(:dnsmasqex, :dnsmasq, value)
          :error -> Application.delete_env(:dnsmasqex, :dnsmasq)
        end

        PropertyTable.delete(VintageNet, config_property)
        Enum.each([hosts_path, pid_path, hosts_path <> ".new"], &File.rm_rf!/1)
      end)

      %{
        hosts_path: hosts_path,
        pid_path: pid_path,
        conf_path: Path.join(tmpdir, "dnsmasq.conf.ioctl0")
      }
    end

    test "keeps the current leases when a lease is invalid", %{hosts_path: hosts_path} do
      assert {:error, "Invalid MAC address \"not-a-mac\""} =
               Dnsmasqex.ioctl("ioctl0", :static_leases, [
                 [{"not-a-mac", "192.168.24.100"}]
               ])

      assert File.read!(hosts_path) == "aa:bb:cc:dd:ee:ff,192.168.24.100,infinite\n"
    end

    test "writes nothing when dnsmasq isn't running", %{hosts_path: hosts_path} do
      assert {:error, :not_running} =
               Dnsmasqex.ioctl("ioctl0", :static_leases, [
                 [{"aa:bb:cc:dd:ee:01", "192.168.24.101"}]
               ])

      assert File.read!(hosts_path) == "aa:bb:cc:dd:ee:ff,192.168.24.100,infinite\n"
    end

    test "rejects malformed lease collections without changing the file", %{hosts_path: path} do
      assert {:error, "Expected a list for :static_leases, got: nil"} =
               Dnsmasqex.ioctl("ioctl0", :static_leases, [nil])

      assert File.read!(path) == "aa:bb:cc:dd:ee:ff,192.168.24.100,infinite\n"
    end

    test "rejects enabling DHCP through a reload", %{hosts_path: path} do
      config = Dnsmasqex.normalize(%{@config | dnsmasq: %{}})
      PropertyTable.put(VintageNet, ["interface", "ioctl0", "config"], config)

      assert {:error, :dhcp_disabled} =
               Dnsmasqex.ioctl("ioctl0", :static_leases, [
                 [{"aa:bb:cc:dd:ee:ff", "192.168.24.100"}]
               ])

      assert File.read!(path) == "aa:bb:cc:dd:ee:ff,192.168.24.100,infinite\n"
    end

    @tag :linux
    test "rewrites the leases and signals dnsmasq to reload", context do
      port =
        start_process(
          "trap 'echo reloaded' HUP",
          context.conf_path
        )

      assert :ok =
               Dnsmasqex.ioctl("ioctl0", :static_leases, [
                 [{"aa:bb:cc:dd:ee:01", "192.168.24.101", "printer"}]
               ])

      assert File.read!(context.hosts_path) ==
               "aa:bb:cc:dd:ee:01,192.168.24.101,printer,infinite\n"

      assert_receive {^port, {:data, "reloaded\n"}}, 3000
      refute File.exists?(context.hosts_path <> ".new")
    end

    @tag :linux
    test "concurrent lease updates publish complete files", context do
      start_process("trap ':' HUP", context.conf_path)

      results =
        Task.async_stream(
          1..8,
          fn n ->
            leases = [{"aa:bb:cc:dd:ee:ff", {192, 168, 24, 100 + n}, "printer#{n}"}]
            Dnsmasqex.ioctl("ioctl0", :static_leases, [leases])
          end,
          max_concurrency: 8,
          timeout: 10_000
        )

      assert Enum.all?(results, &(&1 == {:ok, :ok}))

      assert File.read!(context.hosts_path) in Enum.map(
               1..8,
               &"aa:bb:cc:dd:ee:ff,192.168.24.#{100 + &1},printer#{&1},infinite\n"
             )

      refute File.exists?(context.hosts_path <> ".new")
    end

    @tag :linux
    test "returns file errors without replacing the current leases", context do
      start_process(":", context.conf_path)
      File.mkdir!(context.hosts_path <> ".new")

      assert {:error, :eisdir} =
               Dnsmasqex.ioctl("ioctl0", :static_leases, [[]])

      assert File.read!(context.hosts_path) == "aa:bb:cc:dd:ee:ff,192.168.24.100,infinite\n"
    end

    @tag :linux
    test "doesn't match another interface's configuration path", context do
      start_process(":", context.conf_path <> "0")
      assert {:error, :not_running} = Dnsmasqex.ioctl("ioctl0", :reload, [])
    end

    @tag :linux
    test "requires the configuration path to follow the configuration option", context do
      start_process(":", context.conf_path, "--unrelated")
      assert {:error, :not_running} = Dnsmasqex.ioctl("ioctl0", :reload, [])
    end

    @tag :linux
    test "doesn't signal another executable with matching arguments", context do
      start_process(":", context.conf_path)
      Application.put_env(:dnsmasqex, :dnsmasq, System.find_executable("cat"))
      assert {:error, :not_running} = Dnsmasqex.ioctl("ioctl0", :reload, [])
    end

    @tag :linux
    test "doesn't signal a process that reused a stale pid" do
      port =
        start_process(
          "trap 'echo alive' USR1",
          "unrelated"
        )

      {:os_pid, os_pid} = Port.info(port, :os_pid)

      assert {:error, :not_running} = Dnsmasqex.ioctl("ioctl0", :reload, [])

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
