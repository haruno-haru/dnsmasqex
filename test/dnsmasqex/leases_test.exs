# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.LeasesTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias Dnsmasqex.Leases

  test "skips truncated, malformed, and negative lease entries" do
    contents = """
    1000 aa:bb:cc:dd:ee:ff 192.168.24.10 printer
    -1 aa:bb:cc:dd:ee:ff 192.168.24.10 printer *
    1000s aa:bb:cc:dd:ee:ff 192.168.24.10 printer *
    duid 00:01:00:01:aa:bb:cc:dd
    """

    assert Leases.parse(contents, 1000) == []
  end

  test "clamps expired lease durations to zero" do
    assert [%{leasetime: 0}] =
             Leases.parse("900 aa:bb:cc:dd:ee:ff 192.168.24.10 printer *\n", 1000)
  end

  test "reads mixed DHCPv4 and DHCPv6 leases without confusing IAIDs with MAC addresses" do
    contents = """
    1500 aa:bb:cc:dd:ee:ff 192.168.24.10 esp32 *
    duid 00:01:00:01:aa:bb:cc:dd
    1600 42 fd12:3456:789a:1::10 esp32 00:03:00:01:aa:bb:cc:dd:ee:ff
    0 T4294967295 fd12:3456:789a:1::20 * 00:03:00:01:aa:bb:cc:dd:ee:01
    vendorclass fd12:3456:789a:1::10 00:01
    1600 invalid fd12:3456:789a:1::30 * 00:03:00:01:aa:bb:cc:dd:ee:02
    1600 4294967296 fd12:3456:789a:1::30 * 00:03:00:01:aa:bb:cc:dd:ee:02
    1600 TT42 fd12:3456:789a:1::30 * 00:03:00:01:aa:bb:cc:dd:ee:02
    1600 +42 fd12:3456:789a:1::30 * 00:03:00:01:aa:bb:cc:dd:ee:02
    1600 42 not-an-address * *
    """

    assert [
             %{lease_mac: "aa:bb:cc:dd:ee:ff", leasetime: 500},
             %{
               lease_mac: nil,
               lease_iaid: "42",
               lease_duid: "00:03:00:01:aa:bb:cc:dd:ee:ff",
               leasetime: 600
             },
             %{lease_mac: nil, lease_iaid: "T4294967295", hostname: "", leasetime: :infinity}
           ] = Leases.parse(contents, 1000)
  end

  @tag :tmp_dir
  test "publishes an empty lease file and clears unreadable leases", %{tmp_dir: tmp_dir} do
    ifname = "dnsmasq_lease0"
    property = ["interface", ifname, "dhcpd", "leases"]
    path = Path.join(tmp_dir, "dnsmasq.leases")
    on_exit(fn -> Leases.clear(ifname) end)

    File.write!(path, "")
    assert :ok = Leases.update(ifname, path)
    assert VintageNet.get(property) == []

    File.rm!(path)

    assert capture_log(fn -> assert :ok = Leases.update(ifname, path) end) =~
             "Failed to read dnsmasq leases"

    assert VintageNet.get(property) == nil
  end
end
