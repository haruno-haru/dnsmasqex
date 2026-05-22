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

* `:start` and `:end` - DHCP address range on the interface's subnet. Without
  them, only static leases get addresses, or only DNS runs if there are none
* `:lease_time` - seconds, from 120 to 4_294_967_294, or `:infinite`
* `:static_leases` - `{mac, ip}` or `{mac, ip, hostname}` tuples with infinite
  leases
* `:records` - `{name, ip}` pairs, including their subdomains
* `:options` - DHCP options, as in `VintageNet.IP.DhcpdConfig`. dnsmasq sends
  its own address as the router and DNS server unless `:router` or `:dns` is
  set, and `[]` sends neither. Integer options are passed to dnsmasq unmodified,
  so they use its `--dhcp-option` format, such as `43 => "4d:53:46:54"`, and
  dnsmasq logs and skips values it can't parse
* `:name_servers` - upstream DNS servers. Without it, dnsmasq follows the name
  servers VintageNet writes to `/etc/resolv.conf`. `[]` forwards nothing
* `:forward_domains` - `{domain, servers}` pairs that forward a domain and its
  subdomains to their own servers. `[]` answers them only from local names
* `:domain` - the local domain. DHCP clients and records without a dot get
  names in it, clients get it as their domain, and its names are never forwarded
* `:hosts_dir` - an absolute path to a directory of `dhcp-host` files. New files
  are read automatically

Don't combine `:dnsmasq` with `:dhcpd` or `:dnsd` on the same interface.
Static leases must have unique MAC and IP addresses and cannot use the server's
address or the subnet's network or broadcast address.

## Changing leases and options at runtime

To change the static leases or DHCP options without reconfiguring the
interface, run:

```elixir
VintageNet.ioctl("eth1", :static_leases, [[{"aa:bb:cc:dd:ee:ff", "192.168.24.100"}]])
VintageNet.ioctl("eth1", :options, [%{router: []}])
```

Clients get the new options when they next renew their lease.

Static leases need DHCP to be enabled through a range, static leases, or
`:hosts_dir`.
A DNS-only configuration returns `{:error, :dhcp_disabled}`; use
`VintageNet.configure/2` to enable DHCP first.

dnsmasq reads new files in `:hosts_dir` on its own. After changing or removing
one, run:

```elixir
VintageNet.ioctl("eth1", :reload)
```

Values set this way last until VintageNet rewrites the interface's files, for
example when its configuration changes, VintageNet restarts, or the device
reboots. dnsmasq reports every lease again as an `"old"` event when it reloads.

## Properties

Property        | Values                      | Description
--------------- | --------------------------- | -----------
`dhcpd/leases`  | `[%{}, ...]`                | Current leases, in the same format as VintageNet's `:dhcpd`. `leasetime` is `:infinity` for infinite leases
`dnsmasq/event` | `%Dnsmasqex.Event{}` | The latest lease or neighbor event. See `Dnsmasqex.Event`

## Development

Run `mix test`, `mix format --check-formatted`, `mix credo --strict`, and
`mix dialyzer`. Linux runs the process identity and signal tests. Installing
dnsmasq also enables tests that check generated configuration with
`dnsmasq --test`.
