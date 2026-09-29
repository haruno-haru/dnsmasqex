# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.PreflightTest do
  use ExUnit.Case, async: true

  alias Dnsmasqex.Config
  alias Dnsmasqex.Preflight

  @moduletag :tmp_dir

  test "checks the features needed by each configuration", %{tmp_dir: tmpdir} do
    command = Path.join(tmpdir, "dnsmasq")

    File.write!(command, """
    #!/bin/sh
    echo 'Dnsmasq version 2.91'
    echo 'Compile time options: no-IPv6 DHCP no-DHCPv6 no-scripts no-inotify no-nftset'
    """)

    File.chmod!(command, 0o700)

    config =
      Config.normalize(%{
        ipv6: %{method: :static, address: "fd12::1", prefix_length: 64},
        dnsmasq: %{dhcpv6: %{mode: :stateless}, hosts_dir: tmpdir}
      })

    assert {:error, {:missing_features, missing}} =
             Preflight.check(command, "unused.conf", Config.required_features(config), [])

    assert Enum.sort(missing) == [:dhcpv6, :inotify, :ipv6, :scripts]
  end

  @tag :dnsmasq
  test "checks runtime files which dnsmasq --test otherwise ignores", %{tmp_dir: tmpdir} do
    path = Path.join(tmpdir, "options")
    conf = Path.join(tmpdir, "dnsmasq.conf")
    File.write!(path, "6,not-an-address\n")
    File.write!(conf, "dhcp-optsfile=#{path}\n")

    assert {_output, 0} = System.cmd("dnsmasq", ["--test", "-C", conf], stderr_to_stdout: true)

    assert {:error, {:invalid_configuration, reason}} =
             Preflight.check("dnsmasq", conf, [:dhcp], options: path)

    assert reason =~ "bad IP address"
    assert Path.wildcard(Path.join(tmpdir, ".dnsmasq-check-*")) == []

    File.write!(path, "6,192.0.2.1\n")
    assert :ok = Preflight.check("dnsmasq", conf, [:dhcp], options: path)
    assert Path.wildcard(Path.join(tmpdir, ".dnsmasq-check-*")) == []
  end

  @tag :dnsmasq
  test "rejects unreadable runtime files before starting", %{tmp_dir: tmpdir} do
    missing = Path.join(tmpdir, "missing")

    assert {:error, {:read_file, ^missing, :enoent}} =
             Preflight.check("dnsmasq", "/dev/null", [], static_leases6: missing)
  end

  test "cleans up when an executable disappears", %{tmp_dir: tmpdir} do
    assert {:error, {:executable, "/nonexistent/dnsmasq", :enoent}} =
             Preflight.runtime("/nonexistent/dnsmasq", :options, "6,192.0.2.1\n", tmpdir)

    assert File.ls!(tmpdir) == []
  end

  @tag :dnsmasq
  test "validates external DHCP directories with the native backup-file rules", %{tmp_dir: tmpdir} do
    directory = Path.join(tmpdir, "hosts")
    config = Path.join(tmpdir, "dnsmasq.conf")
    File.write!(config, "")
    File.mkdir!(directory)
    File.write!(Path.join(directory, "device"), "# wired device\n02:00:00:00:00:02,192.0.2.100\n")

    for name <- [".hidden", "device~", "#backup#"],
        do: File.write!(Path.join(directory, name), "id:01:02,[broken]\n")

    assert :ok = Preflight.check("dnsmasq", config, [:dhcp], static_leases: directory)
    File.write!(Path.join(directory, "#active"), "id:01:02,[broken]\n")

    assert {:error, {:invalid_configuration, _}} =
             Preflight.check("dnsmasq", config, [:dhcp], static_leases: directory)
  end
end
