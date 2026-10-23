Target: linux-bluetooth@vger.kernel.org, plain-text mail. CC the author of the commit and
`luiz.dentz@gmail.com` (Bluetooth maintainer). This is the venue where an actual fix can
happen — GitHub and Launchpad only help other users find the workaround.

---

Subject: Bluetooth: L2CAP: MTUsig rejection breaks Huawei FreeBuds (regression)

Hi,

commit "Bluetooth: L2CAP: reject BR/EDR signaling packets over MTUsig" makes
l2cap_sig_channel() discard any signalling packet larger than L2CAP_SIG_MTU (48)
and answer with L2CAP_REJ_MTU_EXCEEDED. This breaks Huawei FreeBuds 3, and most
likely other FreeBuds models, which can no longer complete a connection.

The earbuds send battery telemetry as a 68-byte Echo Request on the signalling
channel:

  <--  L2CAP Echo Request    ident=129 len=64
       payload: "AT+HUAWEIBATTERY=6,2,100,3,0,4,100,5,0,6,35,7,0\r"
  -->  L2CAP Command Reject  reason=1 (Signalling MTU exceeded) max_mtu=48

Because the whole packet is dropped, the request never reaches

  case L2CAP_ECHO_REQ:
          l2cap_send_cmd(conn, cmd->ident, L2CAP_ECHO_RSP, cmd_len, data);

and no Echo Response is sent. Before the commit the kernel answered it.

The device does proceed to open AVDTP (PSM 0x19) and AVCTP (PSM 0x17); the host
accepts both and sends Config Requests. No Config Response ever arrives, and the
remote terminates the ACL roughly 160 ms later:

  Connect Complete      status=0x00
  Link Key Request
  Auth Complete         status=0x00
  Encryption Change     status=0x00 enabled=1
  ...
  Disconnect Complete   status=0x00 reason=0x13 (Remote User Terminated)

Authentication and encryption succeed every time; the device simply gives up.
The cycle repeats every 3-4 seconds indefinitely.

Raising L2CAP_SIG_MTU to 672 and rebuilding bluetooth.ko restores normal
operation: first-attempt connect, stable A2DP. Nothing else was changed.

I am aware the device is out of spec - Core 5.4, Vol 3, Part A, section 4 puts
MTUsig at 48 octets, and 4.1 does prescribe discarding. The commit message
explains the deviation from "silently discard" well. My concern is only the
scope of the drop: discarding the entire packet, including commands that fit,
turns a tolerated vendor quirk into a hard failure for hardware that worked
before.

Two directions that would keep interop:

  - keep walking the packet and process commands up to MTUsig, rejecting only
    what does not fit; or
  - answer L2CAP_ECHO_REQ regardless of size, since the response is echoed back
    to the peer and needs no state.

I am happy to test patches. Captures were taken with tcpdump on
bluetooth-monitor, because btmon from bluez 5.72 aborts with a buffer overflow
on this system; full traces, analysis and a reproduction setup are at

  REPO_URL

Environment: Ubuntu 24.04, 6.8.0-147-generic, BlueZ 5.72, Intel AX201
(ibt-17-16-1, FW 155-35.23). A JBL TUNE770NC on the same host is unaffected.

Related user reports, all closed without diagnosis: bluez/bluez#2526, #351,
#745, #1011, #1646, #1743.

Thanks,
