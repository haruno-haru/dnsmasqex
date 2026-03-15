# Dnsmasqex

`Dnsmasqex` runs [dnsmasq](https://thekelleys.org.uk/dnsmasq/doc.html)
as the DHCP and DNS server on a `VintageNet` interface. Unlike `:dnsd`, it
forwards names it doesn't know, so clients can use it as their only DNS server.

dnsmasq isn't in the official Nerves systems. Add `BR2_PACKAGE_DNSMASQ=y` to a
custom system, then add `:dnsmasqex` to your dependencies:

```elixir
def deps do
  [
    {:dnsmasqex, "~> 0.1.0", targets: @all_targets}
  ]
end
```

Set the path if dnsmasq isn't on the `PATH`:

```elixir
config :dnsmasqex, dnsmasq: "/usr/sbin/dnsmasq"
```

## Using

Wrap the technology that manages the interface. The interface needs a static
IPv4 address.

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

The following fields are supported:

* `:start` and `:end` - DHCP address range. Omit them for DNS only
* `:lease_time` - seconds or `:infinite`
* `:static_leases` - `{mac, ip}` pairs with infinite leases
* `:records` - `{name, ip}` pairs, including their subdomains

## Properties

Property        | Values                      | Description
--------------- | --------------------------- | -----------
`dhcpd/leases`  | `[%{}, ...]`                | Current leases, in the same format as VintageNet's `:dhcpd`. `leasetime` is `:infinity` for infinite leases
`dnsmasq/event` | `%Dnsmasqex.Event{}` | The latest lease or neighbor event. See `Dnsmasqex.Event`
