[![CI](https://github.com/haruno-haru/dnsmasqex/actions/workflows/ci.yml/badge.svg)](https://github.com/haruno-haru/dnsmasqex/actions/workflows/ci.yml)
[![REUSE status](https://api.reuse.software/badge/github.com/haruno-haru/dnsmasqex)](https://api.reuse.software/info/github.com/haruno-haru/dnsmasqex)

`Dnsmasqex` adds [dnsmasq](https://thekelleys.org.uk/dnsmasq/doc.html)
DHCP and DNS servers to `VintageNet` interfaces. It wraps the technology that
manages the interface, such as
[`VintageNetEthernet`](https://github.com/nerves-networking/vintage_net_ethernet)
or [`VintageNetWiFi`](https://github.com/nerves-networking/vintage_net_wifi) in
access point mode, and takes the place of VintageNet's `:dhcpd` and `:dnsd`.
Unlike `:dnsd`, it forwards names it doesn't know, so clients can use it as
their only DNS server.

To use it, add `:dnsmasqex` to your `mix` dependencies like this:

```elixir
def deps do
  [
    {:dnsmasqex, "~> 0.1.0", targets: @all_targets}
  ]
end
```

> Dnsmasqex also requires dnsmasq, which isn't in the official Nerves
> systems. In Buildroot, enable `BR2_PACKAGE_DNSMASQ`. dnsmasq needs its DHCP
> and script support, which its default build includes.
>
> If dnsmasq isn't on the `PATH`, set its location:
>
> ```elixir
> config :dnsmasqex, dnsmasq: "/usr/sbin/dnsmasq"
> ```

## Using

Dnsmasqex runs on an interface with a static IPv4 address. Set `:type`
to `Dnsmasqex`, `:technology` to the technology that manages the
interface, and put the dnsmasq settings under `:dnsmasq`. For example, to hand
out addresses on a second Ethernet port:

```elixir
config :vintage_net,
  config: [
    {"eth1",
     %{
       type: Dnsmasqex,
       technology: VintageNetEthernet,
       ipv4: %{method: :static, address: "192.168.24.1", prefix_length: 24},
       dnsmasq: %{
         start: "192.168.24.10",
         end: "192.168.24.99",
         domain: "lan",
         static_leases: [{"aa:bb:cc:dd:ee:ff", "192.168.24.100", "printer"}],
         records: [{"device", "192.168.24.1"}]
       }
     }}
  ]
```

You can also set the configuration at runtime:

```elixir
iex> VintageNet.configure("eth1", %{
    type: Dnsmasqex,
    technology: VintageNetEthernet,
    ipv4: %{method: :static, address: "192.168.24.1", prefix_length: 24},
    dnsmasq: %{start: "192.168.24.10", end: "192.168.24.99"}
  })
:ok
```

In the above, IP addresses were passed as strings for convenience, but it's also
possible to pass tuples like `{192, 168, 24, 1}`. VintageNet internally works
with tuples.

The following fields are supported:

* `:start` and `:end` - DHCP address range on the interface's subnet. Without
  them, only static leases get addresses, or only DNS runs if there are none
* `:lease_time` - seconds, from 120 to 4_294_967_294, or `:infinite`
* `:static_leases` - `{mac, ip}` or `{mac, ip, hostname}` tuples with infinite
  leases, or maps with a `:mac` and any of `:ip`, `:hostname` and `:lease_time`.
  A map lease with an `:ip` is infinite unless it has a `:lease_time`, and
  `%{mac: mac, ignore: true}` never answers that client
* `:options` - DHCP options, as in `VintageNet.IP.DhcpdConfig`. dnsmasq sends
  its own address as the router and DNS server unless `:router` or `:dns` is
  set, and `[]` sends neither. Integer options are passed to dnsmasq unmodified,
  so they use its `--dhcp-option` format, such as `43 => "4d:53:46:54"`. Their
  syntax and encoded payload length aren't validated; the caller must keep
  the payload within 255 bytes. dnsmasq logs and skips invalid values
* `:authoritative` - `true` when dnsmasq is the only DHCP server on the network,
  so clients with leases it doesn't know get addresses right away
* `:lease_path` - an absolute path for the lease file, so leases survive a
  reboot when it's on a persistent filesystem. Defaults to VintageNet's `:tmpdir`
* `:hosts_dir` - an absolute path to a directory of `dhcp-host` files. It's
  created if missing, and new files are read automatically. Requires
  `inotify` in `Dnsmasqex.capabilities/0`
* `:domain` - the local domain. DHCP clients and records without a dot get
  names in it, clients get it as their domain, and its names are never forwarded
* `:records` - `{name, ip}` pairs for exactly those names, like `:dnsd`
* `:domain_records` - `{domain, ip}` pairs that also answer every subdomain. The
  domain may use dnsmasq's patterns, such as `"*.example.com"` for only the
  subdomains, or be `"#"` for every name not found elsewhere
* `:cnames` - `{alias, target}` pairs. dnsmasq only answers them when it knows
  the target from records or DHCP
* `:srv_records` - `{name, target, port}` or
  `{name, target, port, priority, weight}` tuples. A target of `"."` marks
  the service as unavailable
* `:txt_records` - `{name, text}` or `{name, [text]}` pairs
* `:mx_records` - `{name, target}` or `{name, target, preference}` tuples
* `:name_servers` - upstream DNS servers. Without it, dnsmasq follows the name
  servers VintageNet writes to `/etc/resolv.conf`. `[]` forwards nothing
* `:forward_domains` - `{domain, servers}` pairs that forward a domain and its
  subdomains to their own servers. `[]` answers them only from local names
* `:nftsets` - `{domains, sets}` pairs that add the addresses dnsmasq resolves
  for the domains to nftables sets, such as
  `{["example.com"], ["inet#filter#allowed"]}`. A set may start with `4#` or `6#`
  to take only that family. Domains include their subdomains; `"#"` matches
  all domains. Wildcards aren't supported. See [Checking dnsmasq and the
  kernel](#checking-dnsmasq-and-the-kernel)

Don't combine `:dnsmasq` with `:dhcpd` or `:dnsd` on the same interface.
Static leases must have unique MAC and IP addresses and cannot use the server's
address or the subnet's network or broadcast address.

WiFi access point example, in place of `:dhcpd`:

```elixir
iex> VintageNet.configure("wlan0", %{
    type: Dnsmasqex,
    technology: VintageNetWiFi,
    vintage_net_wifi: %{networks: [%{mode: :ap, ssid: "test ssid", key_mgmt: :none}]},
    ipv4: %{method: :static, address: "192.168.24.1", netmask: "255.255.255.0"},
    dnsmasq: %{start: "192.168.24.2", end: "192.168.24.10"}
  })
```

Fixed addresses and names for known clients example:

```elixir
dnsmasq: %{
  start: "192.168.24.10",
  end: "192.168.24.99",
  domain: "lan",
  authoritative: true,
  lease_path: "/data/dnsmasq/eth1.leases",
  static_leases: [
    {"aa:bb:cc:dd:ee:01", "192.168.24.101", "esp32"},
    %{mac: "aa:bb:cc:dd:ee:02", ip: "192.168.24.102", hostname: "camera", lease_time: 600},
    %{mac: "aa:bb:cc:dd:ee:03", ignore: true}
  ]
}
```

Clients reach each other as `esp32.lan` and `camera.lan`.

Isolated network example, with no gateway and no upstream DNS:

```elixir
dnsmasq: %{
  start: "192.168.24.10",
  end: "192.168.24.99",
  domain: "lan",
  options: %{router: []},
  name_servers: [],
  records: [{"device", "192.168.24.1"}]
}
```

Captive portal example, answering every name with the device's address:

```elixir
dnsmasq: %{
  start: "192.168.24.10",
  end: "192.168.24.99",
  domain_records: [{"#", "192.168.24.1"}]
}
```

DNS records example:

```elixir
dnsmasq: %{
  domain: "lan",
  records: [{"device", "192.168.24.1"}, {"nas", "192.168.24.50"}],
  cnames: [{"www.lan", "device.lan"}],
  srv_records: [{"_http._tcp.lan", "device.lan", 80}],
  txt_records: [{"device.lan", "model=rpi5"}],
  domain_records: [{"*.apps.lan", "192.168.24.1"}]
}
```

Forwarding example, sending one domain to its own servers and the rest to
public ones:

```elixir
dnsmasq: %{
  name_servers: ["1.1.1.1", "9.9.9.9"],
  forward_domains: [{"corp.example.com", ["10.0.0.53"]}]
}
```

## Changing leases, options and records at runtime

The static leases, DHCP options and `:records` can change without
reconfiguring the interface or restarting dnsmasq. For example, to give a client
a fixed address and later move it:

```elixir
iex> VintageNet.ioctl("eth1", :add_static_lease, [{"aa:bb:cc:dd:ee:04", "192.168.24.103", "esp32"}])
:ok
iex> VintageNet.ioctl("eth1", :put_static_lease, [{"aa:bb:cc:dd:ee:04", "192.168.24.104", "esp32"}])
:ok
iex> VintageNet.ioctl("eth1", :add_static_lease, [{"aa:bb:cc:dd:ee:05", "192.168.24.104"}])
{:error, {:ip_in_use, {"aa:bb:cc:dd:ee:04", {192, 168, 24, 104}, "esp32"}}}
```

Command                | Arguments           | Description
---------------------- | ------------------- | -----------
`:static_leases`       | `[leases]`          | Replace the static leases
`:add_static_lease`    | `[lease]`           | Add a lease. Returns `{:error, {:mac_in_use, lease}}` or `{:error, {:ip_in_use, lease}}` with the static lease that already has the MAC or address
`:put_static_lease`    | `[lease]`           | Add a lease or replace the one with the same MAC. Returns `{:error, {:ip_in_use, lease}}` when another MAC has the address
`:remove_static_lease` | `[mac]`             | Remove the lease for a MAC
`:records`             | `[records]`         | Replace the records
`:add_record`          | `[{name, ips}]`     | Add the addresses for a new name. Returns `{:error, {:name_in_use, records}}` when the name has records
`:put_record`          | `[{name, ips}]`     | Replace the addresses for a name
`:remove_record`       | `[name]`            | Remove the records for a name
`:options`             | `[options]`         | Replace the DHCP options
`:put_option`          | `[option, value]`   | Set one DHCP option
`:delete_option`       | `[option]`          | Remove one DHCP option
`:reload`              | `[]`                | Read the `:hosts_dir` files again

`ips` may be one address or a list. Invalid values return `{:error, reason}`
and leave the current ones in place. Lease commands return
`{:error, :dhcp_disabled}` when the configuration has no range, static leases or
`:hosts_dir`.

Clients get new leases and options when they next renew. If another client has
a dynamic lease on a new static address, dnsmasq refuses that client's renewal
so it moves to another address, and the static client gets the address when it
renews. Check the `dhcpd/leases` property first to see whether that will happen.

The changes are held in memory. Reconfiguring the interface or restarting its
runtime server restores the configured values, including when the interface's
supervision tree restarts. dnsmasq reads new files in `:hosts_dir` on its own,
but needs `:reload` after one changes or is removed.

## Checking dnsmasq and the kernel

dnsmasq builds differ. `Dnsmasqex.capabilities/0` reports the version
and the features dnsmasq was built with, and
`Dnsmasqex.nftables_available?/0` whether the kernel has nf_tables:

```elixir
iex> Dnsmasqex.capabilities()
{:ok, %{version: "2.91", dhcp: true, scripts: true, nftset: false, dnssec: false, ...}}
iex> Dnsmasqex.nftables_available?()
false
```

`:nftsets` needs both. Its nftables tables and sets must already exist, with
names that nftables accepts without quotes. Avoid reserved words such as
`set` and `counter`; keyword restrictions depend on the installed nftables
version and aren't checked here.
`VintageNet.verify_system/0` checks that dnsmasq can serve DHCP and run the
script that reports events.

## Properties

In addition to the common `vintage_net` properties for all interface types, this
technology reports the following:

Property                | Values                       | Description
----------------------- | ---------------------------- | -----------
`dhcpd/leases`          | `[%{}, ...]`                 | Current leases, in the same format as VintageNet's `:dhcpd`. `leasetime` is `:infinity` for infinite leases
`dnsmasq/event`         | `%Dnsmasqex.Event{}` | The latest lease or neighbor event
`dnsmasq/static_leases` | `[lease, ...]`               | The static leases in use
`dnsmasq/options`       | `%{option => value}`         | The DHCP options in use
`dnsmasq/records`       | `[{name, ip}, ...]`          | The records in use

A lease looks like this:

```elixir
%{
  hostname: "esp32",
  lease_mac: "e8:f6:0a:e7:1a:8a",
  lease_nip: "192.168.24.100",
  leasetime: 600
}
```

### Events

dnsmasq reports `"add"`, `"old"` and `"del"` when a lease is added, renewed or
removed, and `"arp-add"` and `"arp-del"` when a client appears or disappears on
the interface's subnet. It also reports every lease as `"old"` when it starts or
reloads. An event looks like this:

```elixir
%Dnsmasqex.Event{
  name: "add",
  mac: "e8:f6:0a:e7:1a:8a",
  ip: "192.168.24.100",
  hostname: "esp32",
  supplied_hostname: "espressif",
  client_id: "01:e8:f6:0a:e7:1a:8a",
  tags: ["known", "eth0"],
  time_remaining: 600,
  requested_options: [1, 3, 28, 6]
}
```

To act on them, subscribe to the property:

```elixir
iex> VintageNet.subscribe(["interface", "eth1", "dnsmasq", "event"])
:ok
iex> flush()
{VintageNet, ["interface", "eth1", "dnsmasq", "event"], nil,
 %Dnsmasqex.Event{name: "add", ...}, %{}}
```

See `Dnsmasqex.Event` for all the fields. dnsmasq checks the neighbor
table at most every 90 seconds, so `"arp-del"` can arrive minutes after a client
goes away. The interface's `lower_up` property changes as soon as the link does.

## Debugging

dnsmasq's output is logged at the `:debug` level. On Nerves, run
`RingLogger.next` or `log_attach` from an IEx prompt, and lower the log level
if needed. dnsmasq logs the lines it can't use in integer `:options` and skips
them rather than failing.

If dnsmasq exits, Dnsmasqex logs the reason and restarts it, waiting
longer each time up to 30 seconds. A common reason is another program already
using port 53 or 67 on the interface's address.

## Development

Run `mix test`, `mix format --check-formatted`, `mix credo --strict`, and
`mix dialyzer`. Linux runs the process identity and signal tests. Installing
dnsmasq also enables tests that check generated configuration with
`dnsmasq --test`.
