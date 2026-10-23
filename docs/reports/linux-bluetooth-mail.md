Target: linux-bluetooth@vger.kernel.org, plain text, no HTML.
CC: Michael Bommarito <michael.bommarito@gmail.com> (author of the commit),
    Luiz Augusto von Dentz <luiz.dentz@gmail.com> (maintainer),
    Marcel Holtmann <marcel@holtmann.org> (maintainer).

---

Subject: Bluetooth: L2CAP: MTUsig rejection breaks Huawei FreeBuds (regression)

Hi,

commit dd214733544427587a95f66dbf3adff072568990 ("Bluetooth: L2CAP: reject
BR/EDR signaling packets over MTUsig") breaks Huawei FreeBuds 3, and very
likely other FreeBuds models: they can no longer complete a connection at
all.

I want to be clear up front that the commit is addressing a real problem and
that the amplification it describes is worth fixing. What follows is a
report of collateral damage, not an argument for a revert.

The earbuds send battery telemetry as a single 68-byte Echo Request on the
signalling channel, after the link is already encrypted:

  <--  L2CAP Echo Request    ident=129 len=64
       payload: "AT+HUAWEIBATTERY=6,2,100,3,0,4,100,5,0,6,35,7,0\r"
  -->  L2CAP Command Reject  reason=1 (Signalling MTU exceeded) max_mtu=48

Because the whole packet is now dropped before dispatch, the request never
reaches

  case L2CAP_ECHO_REQ:
          l2cap_send_cmd(conn, cmd->ident, L2CAP_ECHO_RSP, cmd_len, data);

and no response is sent. The device does go on to open AVDTP (PSM 0x19) and
AVCTP (PSM 0x17); the host accepts both and sends Config Requests. No Config
Response ever arrives and the remote terminates the ACL roughly 160 ms later:

  Connect Complete      status=0x00
  Link Key Request
  Auth Complete         status=0x00
  Encryption Change     status=0x00 enabled=1
  ...
  Disconnect Complete   status=0x00 reason=0x13 (Remote User Terminated)

Authentication and encryption succeed every time; the device simply gives
up. The cycle repeats every 3-4 seconds indefinitely - 36 attempts over four
minutes here, never converging. Audio hardware that worked before the stable
backport landed now never connects, with nothing in the UI to suggest why.

Raising L2CAP_SIG_MTU to 672 and rebuilding bluetooth.ko restores normal
operation: first-attempt connect, stable A2DP. That is what I am running
locally, and I am aware it reopens exactly the vector the commit closed, so
I am not proposing it as a fix.

What I would like to suggest instead comes from the difference between the
two cases. The amplification described in the commit message is a
pre-pairing one: "a Bluetooth BR/EDR peer within radio range, before
pairing, can force 168 ECHO_RSP frames from one 681-byte fixed-channel
signaling packet". The FreeBuds frame arrives after Encryption Change, from
a bonded peer, and is a single command rather than 168 packed ones. Both
properties are cheap to test:

  - enforce MTUsig strictly while the link is unauthenticated or
    unencrypted, and fall back to the previous lenient parsing once
    encryption is enabled; or

  - bound what actually causes the amplification - the number of commands
    dispatched per signalling packet, or the number of ECHO_RSP frames
    generated from one packet - rather than the packet size, which is only
    a proxy for it.

Either keeps the pre-pairing attack closed while letting a bonded device's
single oversized vendor command through.

If neither is acceptable, it would still help users a great deal if the
rejection were visible at info level rather than BT_DBG. Right now the only
symptom is a device that silently never connects, and the reject is
invisible unless you are already capturing HCI traffic.

I am happy to test patches against the real hardware.

A couple of notes on reproducing. btmon from bluez 5.72 aborts with a
fortify "buffer overflow detected" on every live capture on this system, so
the traces above were taken with tcpdump on bluetooth-monitor; that turned
out to be an unrelated bug in print_packet() and is filed as
https://github.com/bluez/bluez/issues/2704. Full traces, a decoder and the
analysis are at

  https://github.com/prostopasta/freebuds-l2cap-sig-mtu

Environment: Ubuntu 24.04, kernel 6.8.0-147-generic (the commit is present
via the stable backport), BlueZ 5.72, Intel AX201 (ibt-17-16-1, FW
155-35.23), Huawei FreeBuds 3. A JBL TUNE770NC on the same host is
unaffected, so this is specific to devices that use oversized signalling
frames.

Also filed against the Ubuntu kernel:
https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2172088

Related user reports, all closed without a diagnosis: bluez/bluez#2526,
#351, #745, #1011, #1646, #1743.

Thanks,
