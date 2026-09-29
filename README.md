[![CI](https://github.com/haruno-haru/dnsmasqex/actions/workflows/ci.yml/badge.svg)](https://github.com/haruno-haru/dnsmasqex/actions/workflows/ci.yml)
[![REUSE status](https://api.reuse.software/badge/github.com/haruno-haru/dnsmasqex)](https://api.reuse.software/info/github.com/haruno-haru/dnsmasqex)

`Dnsmasqex` adds [dnsmasq](https://thekelleys.org.uk/dnsmasq/doc.html)
DHCPv4, DHCPv6, IPv6 router advertisements and DNS servers to `VintageNet`
interfaces. It wraps the technology that
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
    {:dnsmasqex, "~> 0.1.1", targets: @all_targets}
  ]
end
```

> Dnsmasqex also requires dnsmasq, which isn't in the official Nerves
> systems. In Buildroot, enable `BR2_PACKAGE_DNSMASQ`. DHCP and event reporting
> need DHCP and script support. DNS-only configurations also work with reduced builds.
>
> If dnsmasq isn't on the `PATH`, set its location:
>
> ```elixir
> config :dnsmasqex, dnsmasq: "/usr/sbin/dnsmasq"
> ```

Dnsmasqex uses the system's unmodified dnsmasq executable. It does not bundle
or require a patched binary.

## Using

Dnsmasqex runs on an interface with a static IPv4 or IPv6 address. Set `:type`
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

The following fields are supported under `:dnsmasq`. IPv6-specific settings
are described in [IPv6 and dual stack](#ipv6-and-dual-stack).

* `:start` and `:end` - DHCPv4 address range on the interface's subnet. Without
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
  syntax is checked by the installed dnsmasq before startup and runtime
  updates. The caller must still choose the correct payload type and keep it
  within 255 bytes. Named and numeric aliases of the same option cannot appear
  together; `:put_option` replaces either form and `:delete_option` removes either
* `:authoritative` - `true` when dnsmasq is the only DHCP server on the network,
  so clients with leases it doesn't know get addresses right away
* `:lease_path` - an absolute path for the lease file, so leases survive a
  reboot when it's on a persistent filesystem. Defaults to VintageNet's `:tmpdir`
* `:hosts_dir` - an absolute path to a directory of `dhcp-host` files. It's
  created if missing, and new files are read automatically. Requires
  `inotify` in `Dnsmasqex.capabilities/0`
* `:domain` - the local domain. DHCP clients and records without a dot get
  names in it, clients get it as their domain, and its names are never forwarded
* `:records` - `{name, ip}` pairs for exactly those names, like `:dnsd`.
  IPv4 addresses produce A records and IPv6 addresses produce AAAA records
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
  servers in VintageNet's configured `:resolvconf` file (normally `/etc/resolv.conf`).
  `[]` disables resolver-file forwarding. Scoped IPv6 strings such as
  `"fe80::1%eth0"` select the upstream interface. Ports and sources are supported,
  for example `"127.0.0.1#5353"` or `"192.0.2.53@eth0@192.0.2.1#5300"`
* `:forward_domains` - `{domain, servers}` pairs that forward a domain and its
  subdomains to their own servers. `[]` answers them only from local names
* `:nftsets` - `{domains, sets}` pairs that add the addresses dnsmasq resolves
  for the domains to nftables sets, such as
  `{["example.com"], ["inet#filter#allowed"]}`. A set may start with `4#` or `6#`
  to take only that family. Domains include their subdomains; `"#"` matches
  all domains. Wildcards aren't supported. See [Checking dnsmasq and the
  kernel](#checking-dnsmasq-and-the-kernel)
* `:listen_mode` - `:addresses` listens only on the configured static addresses.
  `:interface` listens on all addresses of the interface, including link-local
  IPv6 addresses. Defaults to `:addresses` without router advertisements and
  `:interface` with them. RA requires `:interface`; combining RA with
  `:addresses` is rejected

Don't combine `:dnsmasq` with `:dhcpd` or `:dnsd` on the same interface.
Unknown `:dnsmasq` keys raise an error instead of being ignored.
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

## Advanced native capabilities

Common settings have direct keys: `:port` (0..65535, with 0 disabling DNS),
`:cache_size`, `:dns_forward_max` and `:dhcp_lease_max`. `:user` and `:group`
select daemon credentials after startup. The compatibility default is root;
when using another identity, ensure it can access the configured files.
A native `:dhcp_scriptuser` also needs access to the notification socket;
`:notify_mode` controls the socket's permissions.

Use `:directives` for the remaining native options. It is a keyword list with
underscores in option names, booleans for flags, integers for numeric controls,
and strings for compound native grammar. Repeat keys where dnsmasq allows
multiple entries. The library rejects unknown names, control characters,
overlong lines, and attempts to replace supervision, scripts, binding or
internally managed files. The installed binary then validates the actual syntax
and available features. `Dnsmasqex.Directives.supported/0` lists the catalog.

```elixir
dnsmasq: %{
  port: 5353,
  cache_size: 1000,
  dhcp_lease_max: 2000,
  name_servers: ["127.0.0.1#5300"],
  directives: [
    strict_order: true,
    stop_dns_rebind: true,
    rebind_domain_ok: "/lan/",
    dns_forward_max: 200,
    max_tcp_connections: 50,
    local_ttl: 30,
    ptr_record: "1.24.168.192.in-addr.arpa,gateway.lan",
    caa_record: "example.com,0,issue,ca.example"
  ]
}
```

Capability | Native keys (examples)
---------- | ----------------------
Cache, TTL and retries | `cache_rr`, `min_cache_ttl`, `max_cache_ttl`, `neg_ttl`, `use_stale_cache`, `fast_dns_retry`, `edns_packet_max`
Forwarding and filtering | `strict_order`, `all_servers`, `rev_server`, `dns_loop_detect`, `domain_needed`, `filter_a`, `filter_aaaa`, `filter_rr`
DNSSEC | `dnssec`, `trust_anchor`, `dnssec_check_unsigned`, `dnssec_timestamp`, `dnssec_limits`; supply maintained trust anchors and use a DNSSEC-enabled binary
DNS data | `ptr_record`, `caa_record`, `naptr_record`, `dns_rr`, `host_record`, `interface_name`, `dynamic_host`, `synth_domain`; `host_record` and `cname` accept native TTL syntax
Authoritative DNS | `auth_server`, `auth_zone`, `auth_soa`, `auth_ttl`, `auth_peer`, `auth_sec_servers`
Client classification | `dhcp_mac`, `dhcp_vendorclass`, `dhcp_userclass`, `dhcp_match`, `dhcp_name_match`, `tag_if`, `dhcp_ignore`, `dhcp_option_force`
Multiple pools and subnets | Repeated `dhcp_range`, `shared_network`, `bridge_interface`; use native ranges instead of `:start`/`:end` and `:dhcpv6`
IPv6 prefix lifecycle and RA | `dhcp_range` with `constructor:`, `deprecated`, `off-link`, `ra-names`; `ra_param` for interval, preference and MTU; `dhcp_duid` for DUID-EN
Boot services | `enable_tftp`, `tftp_root`, `tftp_secure`, `dhcp_boot`, `pxe_service`, `pxe_prompt`, `bootp_dynamic`
Relay and lease queries | `dhcp_relay`, `dhcp_split_relay`, `leasequery`; the latter two require dnsmasq 2.92 or newer
Firewall sets and marks | `ipset`, `nftset`, `conntrack`, `connmark_allowlist_enable`, `connmark_allowlist`; create the kernel sets separately
Diagnostics and system integration | `log_queries`, `log_dhcp`, `log_debug`, `dumpfile`, `dumpmask`, `enable_dbus`, `enable_ubus`; buses use the installed daemon's native API and system permissions

DHCP policy data can use `:dhcp_hosts` and `:dhcp_options`, which are reloadable
lists in the native `dhcp-host` and `dhcp-option` grammar:

```elixir
dnsmasq: %{
  name_servers: [],
  directives: [
    dhcp_range: "set:esp,192.168.24.10,192.168.24.99,255.255.255.0,1h",
    dhcp_vendorclass: "set:esp,ESP",
    dhcp_option_force: "tag:esp,option:ntp-server,192.168.24.1"
  ],
  dhcp_hosts: ["id:01:aa:bb:cc:dd:ee:ff,set:esp,192.168.24.100,esp32,1h"],
  dhcp_options: ["tag:esp,option:dns-server,192.168.24.1"]
}
```

Native host entries also support multiple MACs, client IDs, tags and multiple
IPv6 addresses per DUID. Their semantics are checked by dnsmasq, including
interactions with native ranges. The convenient `:static_leases` APIs retain
their stricter single-address checks. Global options and tagged native rules
follow dnsmasq's native precedence.

For prefixes managed externally, including changes applied by another DHCPv6
client, use this instead of a fixed `:dhcpv6` pool:

```elixir
ipv6: %{method: :manual},
dnsmasq: %{
  directives: [
    dhcp_range: "::100,::1ff,constructor:eth1,slaac,64,1h",
    ra_param: "eth1,high,30,1800"
  ]
}
```

The daemon follows suitable addresses on `eth1` as they appear or disappear.
For several static prefixes, configure additional `:ipv6.addresses` and repeated
native ranges. `deprecated` occupies the lease-time position of a native range.
Routing and obtaining delegated prefixes remain the responsibility of the
system. Original dnsmasq is neither a DHCPv6-PD allocator nor a DoH/DoT client;
a local encrypted-DNS proxy can be selected through an upstream custom port.

## IPv6 and dual stack

Set the interface's `:ipv6` address alongside `:ipv4` for dual stack, or use
`ipv4: %{method: :disabled}` for IPv6 only. Dnsmasqex adds the static IPv6
address after the wrapped technology brings up the interface and removes it
on shutdown. It uses Linux's `ip -6 addr` commands; the wrapped technology
continues to handle the link and IPv4. DNS listens according to `:listen_mode`.

The `:ipv6` map accepts `:method`, `:address` and `:prefix_length` for a
static address, with optional `:addresses` containing additional
`%{address: ip, prefix_length: prefix}` entries. `%{method: :manual}` serves
IPv6 on addresses managed externally and selects interface listening.
`%{method: :disabled}` leaves IPv6 unused by this wrapper. Neither mode
disable the kernel's IPv6 stack or configure routes and resolvers; unsupported
fields are rejected.

This example provides SLAAC and DHCPv6 on a local Ethernet network:

```elixir
VintageNet.configure("eth1", %{
  type: Dnsmasqex,
  technology: VintageNetEthernet,
  ipv4: %{method: :static, address: "192.168.24.1", prefix_length: 24},
  ipv6: %{method: :static, address: "fd12:3456:789a:1::1", prefix_length: 64},
  dnsmasq: %{
    start: "192.168.24.10",
    end: "192.168.24.99",
    domain: "lan",
    dhcpv6: %{
      start: "fd12:3456:789a:1::10",
      end: "fd12:3456:789a:1::99",
      mode: :slaac,
      lease_time: 3600
    },
    ra_lifetime: 0,
    options6: %{dns: ["fd12:3456:789a:1::1"], search: ["lan"]},
    static_leases6: [
      %{duid: "00:03:00:01:aa:bb:cc:dd:ee:ff", ip: "fd12:3456:789a:1::100", hostname: "esp32"}
    ],
    records: [{"gateway.lan", "192.168.24.1"}, {"gateway.lan", "fd12:3456:789a:1::1"}],
    name_servers: ["1.1.1.1", "2606:4700:4700::1111"]
  }
})
```

`:dhcpv6` supports these modes:

Mode | Behavior
---- | --------
`:stateful` | Default. Allocate addresses from `:start` to `:end`; add `enable_ra: true` to advertise the prefix and router
`:slaac` | Allocate DHCPv6 addresses and advertise SLAAC; requires `:start` and `:end`
`:static` | Allocate only configured IPv6 reservations; add `enable_ra: true` for advertisements
`:stateless` | Advertise SLAAC and provide DHCPv6 options without allocating addresses
`:ra_only` | Advertise SLAAC without running DHCPv6

The last three modes take no address pool. `:lease_time` inside `:dhcpv6`
accepts seconds from 120 to 4_294_967_294 or `:infinite`. DHCPv6 requires a
prefix length of 64..128; advertisements require /64. Addresses must be on the
interface's subnet. Pools cannot contain the server's address, and reservations
cannot use it or the subnet-router anycast address (the subnet's all-zero host
part). The convenient `:dhcpv6` pool uses the primary prefix; native ranges
allow multiple prefixes. Applying delegated prefixes is supported through
`constructor:`; obtaining them requires an external DHCPv6 client.

`:enable_ra` defaults to `false`; `:slaac`, `:stateless` and `:ra_only` enable
advertisements themselves. `:ra_lifetime` controls the advertised default route:
`0` advertises the prefix without claiming to be a gateway, as in the local
network example, and 600..9000 sets its lifetime in seconds. Omit it to use
dnsmasq's default. For Internet routing, configure a routed prefix, upstream
routes and kernel IPv6 forwarding separately. Dnsmasqex does not enable forwarding.

`:static_leases6` accepts maps with a client `:duid` and `:ip`, plus optional
`:hostname` and `:lease_time`. DUIDs are colon-separated hex bytes, are compared
case-insensitively and must be unique; IPs must also be unique. The default
lease time is infinite. Reservations imply `dhcpv6: %{mode: :static}` when no
`:dhcpv6` setting is present. Use the client's actual DUID from a lease or event;
it need not contain its MAC address.

`:options6` is independent of DHCPv4's `:options`. It supports `:dns` and `:ntp`
IPv6 address lists, `:search` domain lists, and integer DHCPv6 option numbers
whose string values use dnsmasq's `option6:` syntax. IPv6 addresses in raw
values need brackets, for example `%{23 => "[fd12:3456:789a:1::1]"}`. Named
options add the brackets automatically. `dns: []` suppresses the default DNS
option. The installed dnsmasq checks raw syntax; payload types and encoded
lengths remain the caller's responsibility. Named and numeric option aliases
have the same replacement and deletion behavior as DHCPv4.

For IPv6 DNS alone, configure `:ipv6` and omit `:dhcpv6`, `:static_leases6` and
`:enable_ra`. Records, domain records, upstream servers and domain-specific
forwarding accept either IP family. DHCPv6 and advertisements require `:ipv6`
and `:dhcpv6` to be `true` in `Dnsmasqex.capabilities/0`, plus IPv6 in the kernel.

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

IPv6 uses `:static_leases6`, `:add_static_lease6`, `:put_static_lease6`,
`:remove_static_lease6`, `:options6`, `:put_option6` and `:delete_option6` with
the same argument shapes. IPv6 reservations are identified by DUID, so
`:remove_static_lease6` takes `[duid]`, and duplicate clients return
`{:error, {:duid_in_use, lease}}`. Lease updates return `{:error, :dhcpv6_disabled}`
unless stateful DHCPv6 was enabled when the server started. These updates do
not change the address pool or advertisement mode; use `VintageNet.configure/2`
to change those.

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

### Advanced runtime updates

Command | Arguments | Application
------- | --------- | -----------
`:upstreams` | `[directives]` | Replace reloadable `server`, `local` and `rev_server` entries, then HUP
`:dhcp_hosts` | `[lines]` | Replace native reservations, then HUP
`:dhcp_options` | `[lines]` | Replace native option rules, then HUP
`:directives` | `[directives]` | Validate the complete prospective configuration, replace the native file and restart dnsmasq
`:dump_stats` | `[]` | Ask dnsmasq to log its native statistics/cache dump with SIGUSR1

`:upstreams` supplements the static forwarding settings. To control all
forwarding through it, configure `name_servers: []` and put the servers in
`:upstreams` from the start:

```elixir
dnsmasq: %{name_servers: [], upstreams: [server: "127.0.0.1#5353"]}
# Later:
VintageNet.ioctl("eth1", :upstreams, [[server: "127.0.0.1#5354"]])
```

Native directives that change whether DHCP or RA runs, or change native user
selection, require `VintageNet.configure/2`; the update API returns
`{:error, :requires_interface_reconfiguration}`. This keeps generated startup
files and interface binding consistent. A native-record update through
`:directives` briefly restarts DNS; ordinary `:records` updates do not.

An accepted update publishes `dnsmasq/update` with `saved: true` and a state of
`:reload_signaled`, `:restart_signaled`, `:pending_start`, or
`{:signal_failed, reason}`. `:ok` means the file was saved and signaling either
succeeded or is pending startup. HUP provides no acknowledgement that every
client has received new data. Syntax failures leave the previous file and
published configuration intact; a signal failure happens after saving and is
reported as such. Runtime changes are restored to configured values if the
interface supervision tree restarts.

Read structured cache/upstream counters with `Dnsmasqex.statistics("eth1")`.
For externally managed addressing, use
`Dnsmasqex.Statistics.query({address_tuple, dns_port})`. Counters reset when the
daemon restarts and are unavailable with `port=0` or native `no-ident`.

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
`VintageNet.verify_system/0` checks that dnsmasq can execute and report its version.
Each interface then checks the compiled features its configuration actually needs.

Before each daemon start, Dnsmasqex checks the capabilities required by that
interface: DHCP and scripts, IPv6 and DHCPv6 when used, inotify for `:hosts_dir`,
and nftset plus kernel support for `:nftsets`. It also runs `dnsmasq --test`
against the generated configuration and equivalent directives for its runtime
lease and option files, since dnsmasq's own test skips those files.
Runtime lease and option updates pass the same syntax check before replacing
the current file; a rejected update leaves both the file and published value intact.
Existing files in DHCP host and option directories are also included in startup
validation. Later directory changes are read by dnsmasq; use explicit `:reload`
where required by the native directory semantics.

## Properties

In addition to the common `vintage_net` properties for all interface types, this
technology reports the following:

Property                | Values                       | Description
----------------------- | ---------------------------- | -----------
`dhcpd/leases`          | `[%{}, ...]`                 | Current IPv4 and IPv6 leases. IPv4 retains VintageNet's `:dhcpd` format. `leasetime` is `:infinity` for infinite leases
`dnsmasq/event`         | `%Dnsmasqex.Event{}` | The latest lease or neighbor event
`dnsmasq/static_leases` | `[lease, ...]`               | The static leases in use
`dnsmasq/options`       | `%{option => value}`         | The DHCP options in use
`dnsmasq/records`       | `[{name, ip}, ...]`          | The records in use
`dnsmasq/static_leases6` | `[lease, ...]`              | The IPv6 reservations in use
`dnsmasq/options6`      | `%{option => value}`        | The DHCPv6 options in use
`dnsmasq/directives`    | `[directive, ...]` | Configured advanced native options
`dnsmasq/upstreams`     | `[directive, ...]` | Reloadable upstream entries
`dnsmasq/dhcp_hosts`    | `[line, ...]` | Native reservations
`dnsmasq/dhcp_options`  | `[line, ...]` | Native DHCP option rules
`dnsmasq/update`        | `%{saved: boolean(), state: term(), ...}` | Latest runtime update outcome
`dnsmasq/status`        | `%{state: atom(), ...}`     | Daemon lifecycle and startup failures

Status is `:starting`, `:running`, `:retrying`, `:failed` or `:stopped`.
`:running` includes the verified OS `:pid`; it indicates daemon startup, not
an end-to-end network health check. `:retrying` includes `:reason` and
`:retry_in` in milliseconds. `:failed` includes the preflight `:reason`, such
as `{:missing_features, [:dhcpv6]}` or `{:invalid_configuration, message}`.
Fix the reported problem and reconfigure the interface to retry a preflight
failure. Accepted runtime file updates also retry a stopped daemon. Nonzero
exits retain `{:exit_status, code}`. Validation commands and PID readiness have
configurable deadlines (`:preflight_timeout`, default 5000 ms, and
`:startup_timeout`, default 10000 ms). Removing the interface clears these properties.

A lease looks like this:

```elixir
%{
  hostname: "esp32",
  lease_mac: "e8:f6:0a:e7:1a:8a",
  lease_nip: "192.168.24.100",
  leasetime: 600
}
```

IPv6 leases have `lease_mac: nil`, `lease_duid` and `lease_iaid`; dnsmasq's
lease file does not store their MAC addresses. IAIDs are strings, with a `T`
prefix for temporary leases. IPv4 leases also expose `:lease_client_id`.
On `no-RTC` builds, `:lease_length` records the saved duration and `:leasetime`
is `:unknown` unless the current event supplies remaining time. A saved duration
is not an expiry timestamp. Infinite leases remain `:infinity`.
SLAAC addresses are not DHCP leases and do not
appear in this list.

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

DHCPv6 events include `:duid`, `:iaid` and `:server_duid`; `:client_id` also
contains the client DUID. `:mac` is set only when dnsmasq reports it. Neighbor
events retain their MAC address and include either family on the configured
subnets. Link-local IPv6 neighbors are excluded because dnsmasq's neighbor
script arguments do not identify their interface.

## Debugging

dnsmasq's output is logged at `:debug` by default; `:log_level` selects another level. On Nerves, run
`RingLogger.next` or `log_attach` from an IEx prompt, and lower the log level
if needed. Errors found before startup also appear in `dnsmasq/status`.

If dnsmasq exits, Dnsmasqex logs the reason and restarts it, waiting
longer each time up to 30 seconds. A common reason is another program already
using port 53 or 67 on the interface's address.

## Development

Run `mix test`, `mix format --check-formatted`, `mix credo --strict`, and
`mix dialyzer`. Linux runs the process identity, signal and recovery tests.
Installing dnsmasq enables configuration checks and real DNS queries over
UDP and TCP. CI tests the distribution's dnsmasq package.

The packet tests require Linux, root, `iproute2`, `nftables`, Python 3 and dnsmasq. Run
them in a fresh network namespace after `mix deps.get` and `mix test`:

```sh
sudo env "PATH=$PATH" "MIX_HOME=$HOME/.mix" "HEX_HOME=$HOME/.hex" MIX_ENV=test DNSMASQEX_NETWORK_TESTS=1 \
  unshare --net mix test test/dnsmasqex/network_integration_test.exs --no-compile --no-deps-check --trace
```

They create a separate client namespace connected by a virtual Ethernet pair,
use the generated configuration and supervised processes, and verify DHCPv4
and DHCPv6 allocation, renewal, release, decline, pool exhaustion, client-ID
policies, forced options, lease persistence and server DUID stability. They also
verify isolation between simultaneous interfaces and recovery after link loss,
exercise DHCPv6 Confirm, Rapid Commit and temporary addresses, external hosts
directory updates, TFTP transfers, nftables insertion, custom resolver files,
scoped upstream forwarding and RA flags, MTU, priority and prefix renumbering.
CI runs these tests; the ordinary test suite excludes them.
