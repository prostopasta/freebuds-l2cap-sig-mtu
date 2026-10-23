Target: Launchpad bug against the `linux` source package (Ubuntu 24.04 / noble).
Filed as: https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2172088

File it with `ubuntu-bug linux` so the kernel, hardware and BlueZ versions are attached
automatically, then replace the description with the text below.

---

**Title:** Bluetooth: Huawei FreeBuds no longer connect — BR/EDR signalling-MTU check
discards vendor frames

**Description**

Since a recent noble kernel update Huawei FreeBuds 3 pair successfully but never finish
connecting. The ACL link comes up, authentication and encryption succeed, and the earbuds
tear the link down about 160 ms later with `reason 0x13` (Remote User Terminated). The
cycle repeats every 3–4 seconds and never converges — 36 consecutive attempts over four
minutes in my testing.

**Root cause**

The earbuds send battery telemetry as a 68-byte L2CAP Echo Request on the signalling
channel:

```
<--  L2CAP Echo Request    ident=129 len=64
     payload: "AT+HUAWEIBATTERY=6,2,100,3,0,4,100,5,0,6,35,7,0\r"
-->  L2CAP Command Reject  reason=1 (Signalling MTU exceeded) max_mtu=48
```

The noble tree carries the commit *"Bluetooth: L2CAP: reject BR/EDR signaling packets
over MTUsig"* (Michael Bommarito, author date 2026-09-03), which adds `L2CAP_SIG_MTU`
(48) to `include/net/bluetooth/l2cap.h` and makes `l2cap_sig_channel()` discard any
signalling packet above it. The Echo Request therefore never reaches the `L2CAP_ECHO_REQ`
handler and no Echo Response is sent. The device waits for it, stalls, and disconnects.

Vanilla 6.8, 6.12 and 6.15 do not contain this check, so this is specific to trees
carrying that commit.

**Impact**

Bluetooth audio hardware that worked on earlier noble kernels stops working after a
routine kernel update, with no error visible to the user — the device simply never
connects. The failure mode gives no hint that a kernel change is responsible.

**Verification**

Rebuilding only `bluetooth.ko` with `L2CAP_SIG_MTU` raised from 48 to 672 restores normal
operation: the earbuds connect on the first attempt, A2DP comes up, and the link has been
stable since. No other change.

**Suggested handling**

The device is out of spec — Bluetooth Core 5.4, Vol 3, Part A §4 puts MTUsig at 48 octets
— so the commit is correct as written. But discarding the whole packet regresses working
hardware. Continuing to process commands that fit within MTUsig, or answering Echo
Requests regardless of size, would keep interoperability. At minimum this deserves a
release-note mention, since affected users have no way to connect the symptom to the
kernel.

**Environment**

* Ubuntu 24.04, kernel 6.8.0-147-generic (also reproduced on 6.8.0-146-generic)
* BlueZ 5.72, PipeWire 1.0.5
* Intel AX201, firmware `ibt-17-16-1` 155-35.23
* Huawei FreeBuds 3
* Control: JBL TUNE770NC connects and plays normally on the same host

**Analysis, patch and build instructions**

https://github.com/prostopasta/freebuds-l2cap-sig-mtu

Note for anyone reproducing: `btmon` from bluez 5.72 in noble aborts immediately with
`*** buffer overflow detected ***`, both to stdout and with `-w`. Traces were captured
with `tcpdump -i bluetooth-monitor` instead; a decoder is in the repository above. That
`btmon` crash is filed separately as https://github.com/bluez/bluez/issues/2704
