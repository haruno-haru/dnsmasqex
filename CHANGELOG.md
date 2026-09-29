# Changelog

## Unreleased

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
* Default DNS to the configured addresses; add explicit interface listening,
  required and selected automatically when router advertisements are enabled.
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
