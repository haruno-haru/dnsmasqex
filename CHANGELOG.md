# Changelog

## Unreleased

* Give each published event a unique ID so repeated identical hooks notify
  subscribers, and refresh lease properties before their event is delivered.
* Follow VintageNet's live interface prefixes when filtering neighbor events,
  including externally managed IPv6 addresses and withdrawn prefixes.
* Verify official Ethernet and WiFi configuration composition, and extend Linux
  network tests for the public VintageNet API, repeated TFTP events and dynamic
  IPv6 neighbors. Clarify configuration compatibility and event delivery limits.

## v0.1.2

* Cancel stale restart timers and recover a failed daemon when its runtime
  server restores the original configuration.
* Match native range comments and quoting when checking service roles, and
  reject malformed address text without losing accepted runtime changes.
* Keep generated DHCPv6 reservations on the primary prefix and exclude every
  configured server address from dynamic pools.
* Preserve generated DHCP pools after clearing reservations, reject runtime role
  changes that need interface reconfiguration, and validate current directories
  when restarting the daemon. Restore original native directives on Server restart.
* Distinguish native proxy pools from address allocation, recognize whitespace in
  native RA ranges, and reject conflicting implicit IPv6 pools and reservations
  that overlap any server address.
* Support advanced native dnsmasq policies through a validated directive catalog:
  DNSSEC, filtering, cache and forwarding controls, tagged DHCP, multiple pools,
  IPv6 prefix constructors, RA parameters, DNS records and authoritative zones,
  TFTP/PXE, relay, lease queries, sets and optional system bus integration.
* Add configurable DNS and upstream ports, source selection, resource limits,
  multiple static IPv6 addresses and externally managed IPv6 interfaces.
* Reload native upstream, reservation and option files; validate complete native
  configuration replacements before restarting the daemon and publish update state.
* Follow VintageNet's resolver file path, correctly identify duration-format leases
  on no-RTC builds, retain client IDs and expose additional event metadata.
* Bound validation and startup readiness, retain numeric exit status, allow daemon
  credential selection, and expose native cache/upstream statistics.
* Check external DHCP directories before startup and expand protocol tests for
  DNS records, cache behavior, TCP fallback, DHCP recovery, TFTP and nftables.

* Validate required system dnsmasq features and generated configuration before
  startup, and validate runtime DHCP files before accepting updates.
* Publish daemon startup, failure, retry and running states with a verified PID.
* Reject unknown options, preserve IPv6 upstream interface scopes, and treat
  named and numeric DHCP option aliases consistently.
* Default DNS-only services to the configured addresses and DHCP allocation to
  interface listening, so simultaneous instances receive their own unicast
  renewals and releases. Require interface listening for router advertisements.
* Exercise real DHCPv4, DHCPv6 and RA packets in isolated Linux namespaces in CI.
* Add static IPv6 interfaces, dual-stack DNS, DHCPv6 address pools and
  reservations, SLAAC and router advertisements.
* Support DHCPv6 options and reservation updates without restarting dnsmasq.
* Parse IPv6 leases and DHCPv6 events with DUIDs and IAIDs, and report IPv6
  neighbors on the configured subnet.
* Reject unsupported IPv6 interface fields, exclude scoped IPv6 neighbors,
  and keep runtime DHCP checks and event metadata specific to their address family.

## v0.1.1

No functional changes.

## v0.1.0

Initial release
