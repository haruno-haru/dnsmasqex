# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0

"""A bounded wire-level client for the isolated Linux integration tests."""

import ipaddress
import json
import os
import socket
import struct
import sys
import threading

IFACE = "dnscli0"
MAC = bytes.fromhex("020000000002")
DUID = b"\x00\x03\x00\x01" + MAC
SERVER4 = os.environ.get("DNSMASQEX_SERVER4", "192.0.2.1")
SERVER6 = os.environ.get("DNSMASQEX_SERVER6", "fd12:3456:789a:1::1")
SEARCH = b"\x03lan\x00"


def options6(data):
    result = {}
    while data:
        code, size = struct.unpack("!HH", data[:4])
        assert len(data) >= 4 + size, "truncated DHCPv6 option"
        result[code] = data[4:4 + size]
        data = data[4 + size:]
    return result


def option6(code, data):
    return struct.pack("!HH", code, len(data)) + data


def exchange(sock, packet, destination, matches, attempts=20):
    sock.settimeout(0.4)
    for _ in range(attempts):
        sock.sendto(packet, destination)
        try:
            while True:
                answer, _ = sock.recvfrom(4096)
                if matches(answer):
                    return answer
        except socket.timeout:
            pass
    raise AssertionError(f"No matching response to message {packet[:8].hex()}")


def dhcp4(message, address="0.0.0.0", requested=None, server=None, expected=5, vendor=None):
    transaction = os.urandom(4)
    packet = struct.pack("!BBBB4sHH4s4s4s4s16s64s128s", 1, 1, 6, 0,
                         transaction, 0, 0x8000, socket.inet_aton(address),
                         bytes(4), bytes(4), bytes(4), MAC, b"", b"")
    packet += b"\x63\x82\x53\x63" + bytes([53, 1, message])
    packet += bytes([61, 7, 1]) + MAC + bytes([12, 5]) + b"esp32"
    packet += bytes([55, 5, 1, 3, 6, 15, 51])
    if vendor:
        packet += bytes([60, len(vendor)]) + vendor.encode()
    if requested:
        packet += bytes([50, 4]) + socket.inet_aton(requested)
    if server:
        packet += bytes([54, 4]) + socket.inet_aton(server)
    packet += b"\xff"
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, IFACE.encode() + b"\0")
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.bind(("0.0.0.0", 68))
        if message in (4, 7):
            sock.sendto(packet, (SERVER4 if message == 7 else "255.255.255.255", 67))
            return None
        try:
            answer = exchange(sock, packet, ("255.255.255.255", 67),
                              lambda data: len(data) >= 240 and data[0] == 2 and data[4:8] == transaction,
                              attempts=3 if expected is None else 20)
        except AssertionError:
            if expected is None:
                return None
            raise
        assert expected is not None, "Unexpected DHCP offer"
    result = {}
    data = answer[240:]
    while data and data[0] != 255:
        if data[0] == 0:
            data = data[1:]
        else:
            code, size = data[:2]
            assert len(data) >= size + 2, "truncated DHCPv4 option"
            result[code] = data[2:2 + size]
            data = data[2 + size:]
    assert result[53] == bytes([expected]), result
    return socket.inet_ntoa(answer[16:20]), result


def dhcp6(message, server=None, address=None, rapid=False, temporary=False, status=0):
    transaction = os.urandom(3)
    packet = bytes([message]) + transaction + option6(1, DUID)
    if server:
        packet += option6(2, server)
    if message != 11:
        association = struct.pack("!I", 42) if temporary else struct.pack("!III", 42, 0, 0)
        if address:
            association += option6(5, socket.inet_pton(socket.AF_INET6, address) + bytes(8))
        packet += option6(4 if temporary else 3, association)
    if rapid:
        packet += option6(14, b"")
    packet += option6(6, struct.pack("!HH", 23, 24))
    packet += option6(39, b"\x00\x07esp32v6\x00")
    index = socket.if_nametoindex(IFACE)
    with socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_IF, index)
        sock.bind(("fe80::2", 546, 0, index))
        answer = exchange(sock, packet, ("ff02::1:2", 547, 0, index),
                          lambda data: len(data) >= 4 and data[0] == (2 if message == 1 and not rapid else 7)
                          and data[1:4] == transaction)
    result = options6(answer[4:])
    assert result[1] == DUID
    if 13 in result:
        assert result[13][:2] == struct.pack("!H", status), result[13]
    if server:
        assert result[2] == server
    return result


def address6(result, temporary=False):
    association = result[4 if temporary else 3]
    assert struct.unpack("!I", association[:4])[0] == 42
    nested = options6(association[4 if temporary else 12:])
    assert 5 in nested, nested
    addr, preferred, valid = struct.unpack("!16sII", nested[5])
    assert 0 < preferred <= valid <= 600, (preferred, valid)
    return socket.inet_ntop(socket.AF_INET6, addr)


def check_options(reply4, reply6, dns4, dns6):
    assert reply4[6] == socket.inet_aton(dns4), reply4
    assert reply4[3] == socket.inet_aton(SERVER4), reply4
    assert struct.unpack("!I", reply4[51])[0] == 600, reply4
    assert reply6[23] == socket.inet_pton(socket.AF_INET6, dns6), reply6
    assert reply6[24] == SEARCH, reply6


def lease(action, path, dns4, dns6):
    if action == "acquire":
        offered4, offer4 = dhcp4(1, expected=2)
        addr4, reply4 = dhcp4(3, requested=offered4, server=socket.inet_ntoa(offer4[54]))
        assert addr4 == offered4
        offer6 = dhcp6(1)
        reply6 = dhcp6(3, offer6[2], address6(offer6))
        addr6 = address6(reply6)
        assert ipaddress.ip_address(addr4) in ipaddress.ip_network(SERVER4 + "/24", strict=False)
        assert ipaddress.ip_address(addr6) in ipaddress.ip_network(SERVER6 + "/64", strict=False)
        state = {"ipv4": addr4, "ipv6": addr6, "server": reply6[2].hex()}
        with open(path, "w", encoding="utf-8") as file:
            json.dump(state, file)
    else:
        with open(path, encoding="utf-8") as file:
            state = json.load(file)
        server = bytes.fromhex(state["server"])
        if action == "release":
            dhcp4(7, state["ipv4"], server=SERVER4)
            dhcp6(8, server, state["ipv6"])
            return
        addr4, reply4 = dhcp4(3, state["ipv4"])
        reply6 = dhcp6(5, server, state["ipv6"])
        assert addr4 == state["ipv4"]
        assert address6(reply6) == state["ipv6"]
        rebound = dhcp6(6, address=state["ipv6"])
        assert address6(rebound) == state["ipv6"]
        assert rebound[2] == server
    check_options(reply4, reply6, dns4, dns6)
    print(state["ipv4"], state["ipv6"])


def advertisement(mode):
    index = socket.if_nametoindex(IFACE)
    with socket.socket(socket.AF_INET6, socket.SOCK_RAW, socket.IPPROTO_ICMPV6) as sock:
        sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_IF, index)
        sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_HOPS, 255)
        sock.bind(("fe80::2", 0, 0, index))
        answer = exchange(sock, bytes([133]) + bytes(7), ("ff02::2", 0, 0, index),
                          lambda data: len(data) >= 16 and data[0] == 134)
    managed, other, autonomous = {"stateful": (True, True, False),
                                "slaac": (True, True, True),
                                "stateless": (False, True, True),
                                "ra_only": (False, False, True)}[mode]
    assert bool(answer[5] & 0x80) == managed
    assert bool(answer[5] & 0x40) == other
    assert struct.unpack("!H", answer[6:8])[0] == 0, "unexpected default route"
    found = {}
    data = answer[16:]
    while data:
        code, units = data[:2]
        assert units > 0 and len(data) >= units * 8
        found[code] = data[:units * 8]
        data = data[units * 8:]
    prefix = found[3]
    assert prefix[2] == 64
    assert bool(prefix[3] & 0x40) == autonomous
    assert prefix[3] & 0x80, "prefix must be on-link"
    assert prefix[16:32] == socket.inet_pton(socket.AF_INET6, "fd12:3456:789a:1::")
    valid, preferred = struct.unpack("!II", prefix[4:12])
    assert 0 < preferred <= valid
    assert found[25][8:] == socket.inet_pton(socket.AF_INET6, SERVER6)
    assert found[31][8:].rstrip(b"\0") == SEARCH.rstrip(b"\0")
    if mode == "stateless":
        reply = dhcp6(11)
        assert 3 not in reply, "stateless DHCP must not allocate addresses"
        assert reply[23] == socket.inet_pton(socket.AF_INET6, SERVER6)
        assert reply[24] == SEARCH


def scoped_upstream(ipv4=False):
    # Answer only on a link-local address. Forwarding fails if the scope is lost.
    index = socket.if_nametoindex(IFACE)
    with socket.socket(socket.AF_INET if ipv4 else socket.AF_INET6, socket.SOCK_DGRAM) as upstream:
        upstream.bind(("192.0.2.2", 53) if ipv4 else ("fe80::2", 53, 0, index))
        upstream.settimeout(10)
        errors = []

        def respond():
            try:
                query, sender = upstream.recvfrom(4096)
                assert query[12:34] == b"\x08upstream\x07example\x00\x00\x01\x00\x01"
                response = query[:2] + struct.pack("!HHHHH", 0x8180, 1, 1, 0, 0) + query[12:34]
                response += b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 30, 4)
                upstream.sendto(response + socket.inet_aton("203.0.113.9"), sender)
            except Exception as error:
                errors.append(error)

        worker = threading.Thread(target=respond, daemon=True)
        worker.start()
        query = struct.pack("!HHHHHH", 1234, 0x100, 1, 0, 0, 0)
        query += b"\x08upstream\x07example\x00\x00\x01\x00\x01"
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
            response = exchange(client, query, (SERVER4, 53), lambda data: data[:2] == query[:2])
        worker.join(timeout=11)
        assert not worker.is_alive()
        assert not errors, errors
        assert response[3] & 15 == 0 and response[-4:] == socket.inet_aton("203.0.113.9"), response


def advanced_dhcp6():
    reply = dhcp6(1, rapid=True)
    assert 14 in reply, "Rapid Commit was not acknowledged"
    address = address6(reply)
    confirmed = dhcp6(4, address=address)
    assert confirmed[13][:2] == bytes(2)
    rejected = dhcp6(4, address="fd99::100", status=4)
    assert rejected[13][:2] == b"\x00\x04", "Off-link address was confirmed"
    dhcp6(9, reply[2], address)
    next_reply = dhcp6(1, rapid=True)
    next_address = address6(next_reply)
    assert next_address != address, "Declined address was immediately reused"
    dhcp6(8, next_reply[2], next_address)
    temporary = dhcp6(1, rapid=True, temporary=True)
    temporary_address = address6(temporary, temporary=True)
    dhcp6(8, temporary[2], temporary_address, temporary=True)


def policy4():
    offered, offer = dhcp4(1, expected=2, vendor="ESP")
    address, reply = dhcp4(3, requested=offered, server=socket.inet_ntoa(offer[54]), vendor="ESP")
    assert address == "192.0.2.105", address
    assert reply[42] == socket.inet_aton("192.0.2.123"), "Unrequested forced NTP option is missing"


def decline4():
    offered, offer = dhcp4(1, expected=2)
    address, _ = dhcp4(3, requested=offered, server=socket.inet_ntoa(offer[54]))
    dhcp4(4, requested=address, server=socket.inet_ntoa(offer[54]))
    next_address, _ = dhcp4(1, expected=2)
    assert next_address != address, "Declined IPv4 address was immediately reused"


def tftp(filename, expected):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
        client.settimeout(3)
        client.sendto(b"\x00\x01" + filename.encode() + b"\x00octet\x00", (SERVER4, 69))
        packet, sender = client.recvfrom(2048)
        assert packet[:4] == b"\x00\x03\x00\x01", packet
        assert packet[4:] == expected.encode(), packet
        client.sendto(b"\x00\x04\x00\x01", sender)


def reservation4(expected):
    offered, offer = dhcp4(1, expected=2)
    assert offered == expected, (offered, expected)
    address, _ = dhcp4(3, requested=offered, server=socket.inet_ntoa(offer[54]))
    assert address == expected
    dhcp4(7, address=address, server=socket.inet_ntoa(offer[54]))


def exhausted4():
    global MAC
    offered, offer = dhcp4(1, expected=2)
    address, _ = dhcp4(3, requested=offered, server=socket.inet_ntoa(offer[54]))
    assert address == "192.0.2.100"
    MAC = bytes.fromhex("020000000003")
    assert dhcp4(1, expected=None) is None


def prefixes(expected):
    wanted = {socket.inet_pton(socket.AF_INET6, prefix) for prefix in expected.split(",")}

    def active_prefixes(packet):
        found = set()
        data = packet[16:]
        while len(data) >= 2 and data[1] > 0:
            size = data[1] * 8
            if data[0] == 3 and size == 32 and struct.unpack("!I", data[8:12])[0] > 0:
                found.add(data[16:32])
            data = data[size:]
        return found

    index = socket.if_nametoindex(IFACE)
    with socket.socket(socket.AF_INET6, socket.SOCK_RAW, socket.IPPROTO_ICMPV6) as sock:
        sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_IF, index)
        sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_HOPS, 255)
        sock.bind(("fe80::2", 0, 0, index))
        answer = exchange(sock, bytes([133]) + bytes(7), ("ff02::2", 0, 0, index),
                          lambda data: len(data) >= 16 and data[0] == 134 and active_prefixes(data) == wanted)
    assert answer[5] & 0x18 == 0x08, "RA preference must be high"
    assert b"\x05\x01\x00\x00\x00\x00\x05\x78" in answer[16:], "RA MTU must be 1400"


if __name__ == "__main__":
    action = sys.argv[1]
    if action == "ra":
        advertisement(sys.argv[2])
    elif action == "upstream":
        scoped_upstream()
    elif action == "resolver-upstream":
        scoped_upstream(ipv4=True)
    elif action == "advanced6":
        advanced_dhcp6()
    elif action == "policy4":
        policy4()
    elif action == "decline4":
        decline4()
    elif action == "tftp":
        tftp(sys.argv[2], sys.argv[3])
    elif action == "reservation4":
        reservation4(sys.argv[2])
    elif action == "no-offer4":
        assert dhcp4(1, expected=None) is None
    elif action == "exhausted4":
        exhausted4()
    elif action == "prefixes":
        prefixes(sys.argv[2])
    else:
        lease(action, sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else SERVER6)
