#!/usr/bin/env python3
"""Decode the L2CAP signalling channel from a bluetooth-monitor pcap.

Written because btmon on bluez 5.72 (Ubuntu noble) aborts with a buffer overflow.

    sudo tcpdump -i bluetooth-monitor -s 0 -U -w trace.pcap
    ./l2cap-decode.py trace.pcap

Prints HCI encryption/disconnect events and every L2CAP signalling command, which
is enough to see a connection fall apart. Only first fragments are decoded; that
covers signalling, which never spans ACL fragments in practice.
"""
import struct
import sys

SIG = {0x01: "Command Reject", 0x02: "Conn Request", 0x03: "Conn Response",
       0x04: "Config Request", 0x05: "Config Response", 0x06: "Disconn Request",
       0x07: "Disconn Response", 0x08: "Echo Request", 0x09: "Echo Response",
       0x0a: "Info Request", 0x0b: "Info Response"}
PSM = {0x0001: "SDP", 0x0003: "RFCOMM", 0x0017: "AVCTP", 0x0019: "AVDTP",
       0x001b: "AVCTP-browse"}
CONN_RESULT = {0: "Success", 1: "Pending", 2: "PSM not supported",
               3: "Security block", 4: "No resources"}
REJ = {0: "Command not understood", 1: "Signalling MTU exceeded", 2: "Invalid CID"}
DISC = {0x04: "Page Timeout", 0x05: "Authentication Failure", 0x08: "Connection Timeout",
        0x13: "Remote User Terminated", 0x16: "Terminated By Local Host"}

ACL_TX, ACL_RX, HCI_EVENT = 0x0004, 0x0005, 0x0003


def records(path):
    data = open(path, "rb").read()
    if data[:4] not in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1"):
        sys.exit(f"{path}: not a little-endian pcap")
    off = 24
    while off + 16 <= len(data):
        _, usec, incl, _ = struct.unpack("<IIII", data[off:off + 16])
        off += 16
        yield usec, data[off:off + incl]
        off += incl


def decode_sig(code, payload):
    if code == 0x02 and len(payload) >= 2:
        psm = struct.unpack("<H", payload[:2])[0]
        return f"PSM=0x{psm:04x} ({PSM.get(psm, '?')})"
    if code == 0x03 and len(payload) >= 6:
        r = struct.unpack("<H", payload[4:6])[0]
        return f"result={r} ({CONN_RESULT.get(r, '?')})"
    if code == 0x01 and len(payload) >= 2:
        r = struct.unpack("<H", payload[:2])[0]
        extra = ""
        if r == 1 and len(payload) >= 4:
            extra = f" max_mtu={struct.unpack('<H', payload[2:4])[0]}"
        return f"reason={r} ({REJ.get(r, '?')}){extra}"
    if code == 0x05 and len(payload) >= 6:
        r = struct.unpack("<H", payload[4:6])[0]
        return f"result={r} ({'Success' if r == 0 else 'failure'})"
    if code in (0x08, 0x09):
        text = bytes(c if 32 <= c < 127 else 0x2e for c in payload[:48]).decode()
        return f"len={len(payload)} data={text!r}"
    return ""


def main(path):
    for usec, pkt in records(path):
        if len(pkt) < 4:
            continue
        _, opcode = struct.unpack(">HH", pkt[:4])
        body = pkt[4:]
        stamp = f"{usec // 1000:03d}"

        if opcode == HCI_EVENT and body:
            if body[0] == 0x05 and len(body) >= 6:
                print(f"{stamp}  HCI  Disconnect  reason=0x{body[5]:02x} "
                      f"({DISC.get(body[5], '?')})")
            elif body[0] == 0x08 and len(body) >= 6:
                print(f"{stamp}  HCI  Encryption enabled={body[5]}")
            continue

        if opcode not in (ACL_TX, ACL_RX) or len(body) < 8:
            continue
        pb = (struct.unpack("<H", body[:2])[0] >> 12) & 0x3
        if pb not in (0b00, 0b10):          # continuation fragment
            continue
        _, cid = struct.unpack("<HH", body[4:8])
        sig = body[8:]
        if cid != 0x0001 or len(sig) < 4:
            continue
        code, _ident, plen = sig[0], sig[1], struct.unpack("<H", sig[2:4])[0]
        arrow = "-->" if opcode == ACL_TX else "<--"
        print(f"{stamp}  {arrow}  {SIG.get(code, hex(code)):<17} "
              f"{decode_sig(code, sig[4:4 + plen])}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
