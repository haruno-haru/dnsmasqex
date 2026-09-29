# Changelog

## Unreleased

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
