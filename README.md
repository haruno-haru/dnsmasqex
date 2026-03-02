# Dnsmasqex

`Dnsmasqex` adds [dnsmasq](https://thekelleys.org.uk/dnsmasq/doc.html)
DHCP and DNS servers to `VintageNet` interfaces. Use it when a device hands out
addresses to other devices, for example on a second Ethernet port or a WiFi
access point, and those devices need to resolve Internet names as well as local
ones. VintageNet's `:dhcpd` and `:dnsd` options use busybox, whose DNS server
only answers the names it's configured with.

dnsmasq isn't part of the official Nerves systems, so add it to a custom system
with `BR2_PACKAGE_DNSMASQ=y`. Then add `:dnsmasqex` to your `mix`
dependencies:

```elixir
def deps do
  [
    {:dnsmasqex, "~> 0.1.0", targets: @all_targets}
  ]
end
```

If dnsmasq isn't on the `PATH`, tell `Dnsmasqex` where it is:

```elixir
config :dnsmasqex, dnsmasq: "/usr/sbin/dnsmasq"
```

## Using

`Dnsmasqex` wraps the technology that manages the interface, so the
interface is configured as usual and dnsmasq runs alongside it. The interface
needs a static IPv4 address.

```elixir
iex> VintageNet.configure("eth1", %{
    type: Dnsmasqex,
    technology: VintageNetEthernet,
    ipv4: %{method: :static, address: "192.168.24.1", prefix_length: 24},
    dnsmasq: %{
      start: "192.168.24.10",
      end: "192.168.24.99",
      static_leases: [{"aa:bb:cc:dd:ee:ff", "192.168.24.100"}],
      records: [{"device.example.com", "192.168.24.1"}]
    }
  })
:ok
```

The `:dnsmasq` key supports:

* `:start` and `:end` - the DHCP address range. Without them, dnsmasq only
  serves DNS
* `:lease_time` - seconds or `:infinite`. Defaults to dnsmasq's 1 hour
* `:static_leases` - `{mac, ip}` pairs that always get the same address, with an
  infinite lease
* `:records` - `{name, ip}` pairs answered locally, including their subdomains

Other names are forwarded to the name servers in `/etc/resolv.conf`, which
VintageNet keeps up to date. dnsmasq listens only on the interface's address, so
each interface can run its own instance.

Any technology can be wrapped. Here's a WiFi access point:

```elixir
iex> VintageNet.configure("wlan0", %{
    type: Dnsmasqex,
    technology: VintageNetWiFi,
    vintage_net_wifi: %{
      networks: [%{mode: :ap, ssid: "my_ap", key_mgmt: :wpa_psk, psk: "a_passphrase"}]
    },
    ipv4: %{method: :static, address: "192.168.25.1", prefix_length: 24},
    dnsmasq: %{start: "192.168.25.10", end: "192.168.25.99"}
  })
:ok
```

## Properties

DHCP leases are reported the same way as for VintageNet's `:dhcpd` option, so
code that watches leases works with either.

Property   | Values           | Description
---------- | ---------------- | -----------
`dhcpd/leases` | `[%{lease_mac: String.t(), lease_nip: String.t(), hostname: String.t(), leasetime: non_neg_integer() \| :infinity}]` | Current DHCP leases. `leasetime` is the number of seconds left
