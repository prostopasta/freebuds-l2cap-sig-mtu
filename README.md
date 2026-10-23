# Huawei FreeBuds on Linux: the BR/EDR signalling-MTU regression

Huawei FreeBuds (confirmed on **FreeBuds 3**) pair fine but never finish connecting on
recent kernels. The link comes up, authentication and encryption succeed, and roughly
160 ms later the earbuds tear the ACL down with `reason 0x13` (*Remote User Terminated*).
The cycle repeats every 3–4 seconds, forever.

This repository documents the root cause, carries a one-line kernel patch, and gives two
ways to apply it.

## TL;DR

The earbuds push a **68-byte vendor frame on the L2CAP signalling channel** (an Echo
Request carrying `AT+HUAWEIBATTERY=...`). Since the commit
**"Bluetooth: L2CAP: reject BR/EDR signaling packets over MTUsig"** the kernel drops any
signalling packet larger than `L2CAP_SIG_MTU` (48) and answers
`Command Reject: Signaling MTU exceeded`. The earbuds never get their Echo Response,
stall, and hang up. Raising `L2CAP_SIG_MTU` restores the pre-regression behaviour.

```diff
-#define L2CAP_SIG_MTU			48	/* BR/EDR signaling MTU */
+#define L2CAP_SIG_MTU			672	/* BR/EDR signaling MTU */
```

## Symptoms

* `bluetoothctl connect` fails with `br-connection-canceled` or `br-connection-unknown`.
* `Connected: yes` / `Connected: no` flapping every few seconds in `bluetoothctl`.
* `bluetoothd` logs, repeatedly:

```
src/profile.c:ext_connect() Hands-Free Voice gateway failed connect: Connection reset by peer (104)
profiles/audio/a2dp.c:connect_cb() HUP or ERR on socket: Connection reset by peer (104)
src/adapter.c:dev_disconnected() Device ... disconnected, reason 3
```

* Pairing itself succeeds (`Pairing successful`, `Paired: yes`, `Bonded: yes`).
* The same host connects other A2DP headsets without trouble.
* The same earbuds work normally on Android.

## Root cause

HCI level — crypto is fine, the remote simply hangs up:

```
Connect Complete      status=0x00
Link Key Request
Auth Complete         status=0x00
Encryption Change     status=0x00 enabled=1
Disconnect Complete   status=0x00 reason=0x13 (Remote User Terminated)
```

L2CAP level — the interesting part:

```
<--  L2CAP Echo Request    ident=129 len=64      (68 bytes total, vendor payload)
-->  L2CAP Command Reject  reason=1 (Signaling MTU exceeded) max_mtu=48
<--  L2CAP Conn Request    PSM=0x0019 (AVDTP)
<--  L2CAP Conn Request    PSM=0x0017 (AVCTP)
-->  L2CAP Conn Response   result=0 (Success)
-->  L2CAP Config Request
-->  L2CAP Config Request
     HCI Disconnect  reason=0x13 (Remote User Terminated)
```

The Echo Request payload decodes to ASCII:

```
AT+HUAWEIBATTERY=6,2,100,3,0,4,100,5,0,6,35,7,0
```

so the earbuds use the signalling channel to push battery telemetry. The frame is
68 bytes, which exceeds `MTUsig`. The kernel discards **the whole packet** and replies
with an MTU-exceeded reject; the Config Response the host is waiting for never arrives,
and the earbuds give up.

Bluetooth Core 5.4, Vol 3, Part A §4 does specify MTUsig as 48 octets, so the device is
out of spec. Linux used to be lenient and answered the Echo Request anyway. The new
strictness is what breaks these earbuds.

### Offending change

`include/net/bluetooth/l2cap.h` gained:

```c
#define L2CAP_SIG_MTU			48	/* BR/EDR signaling MTU */
```

and `l2cap_sig_channel()` in `net/bluetooth/l2cap_core.c` gained:

```c
	if (skb->len > L2CAP_SIG_MTU) {
		u8 ident = skb->data[1];

		BT_DBG("signaling packet exceeds MTU: %u > %u",
		       skb->len, L2CAP_SIG_MTU);
		l2cap_sig_send_mtu_rej(conn, ident);
		goto drop;
	}
```

Commit [`dd214733544`](https://github.com/torvalds/linux/commit/dd214733544427587a95f66dbf3adff072568990)
— *"Bluetooth: L2CAP: reject BR/EDR signaling packets over MTUsig"*, Michael Bommarito,
authored 2026-05-21, committed by Luiz Augusto von Dentz 2026-06-03, carrying
`Cc: stable@vger.kernel.org`.

**This is upstream, not a distribution patch.** The stable tag means it reaches every
distribution that follows stable, Ubuntu included. Release tags that predate it — v6.8,
v6.12, v6.15 — do not contain the check, so grepping those comes up empty; that says when
it landed, not who carries it.

### Why the check exists

The commit is not gratuitous. It closes a real pre-pairing amplification vector, in its
author's words:

> a Bluetooth BR/EDR peer within radio range, before pairing, can force 168 ECHO_RSP
> frames from one 681-byte fixed-channel signaling packet containing packed ECHO_REQ
> commands

Raising the limit, as this repository does, **reopens that vector**. See
[Caveats](#caveats).

## Applying the patch

Both methods rebuild only the `bluetooth` module — not the whole kernel — and install it
into `updates/`, which `depmod` prefers over `kernel/` (`search updates ubuntu built-in`
in `/etc/depmod.d/`). **No file shipped by your distribution is modified**, so rolling
back means deleting one file.

Prerequisites: matching `linux-headers-$(uname -r)`, `build-essential`, and Secure Boot
either disabled or your own MOK enrolled (DKMS signs with MOK automatically).

### Method 1 — one-off build from the full kernel source

Use this when you want a module for one specific kernel, or when method 2 fails because
the bundled sources do not match your kernel's internal API.

```sh
sudo apt-get install -y linux-source-$(uname -r | cut -d- -f1) \
                        flex bison libelf-dev dwarves zstd
scripts/build-module.sh                 # builds for the running kernel
sudo scripts/install-module.sh          # installs into updates/ and runs depmod
```

Read `scripts/build-module.sh` before running it; the two things it does that are easy to
get wrong are described in [docs/PITFALLS.md](docs/PITFALLS.md).

### Method 2 — DKMS, survives kernel updates

```sh
sudo cp -a dkms/bluetooth-freebuds-1.0 /usr/src/
sudo dkms add    -m bluetooth-freebuds -v 1.0
sudo dkms install -m bluetooth-freebuds -v 1.0
```

DKMS then rebuilds the module automatically for every kernel you install. The package
carries the Bluetooth subsystem sources it was cut from, plus the patched headers, and
builds against `linux-headers` alone — no `linux-source` needed.

### Applying the module

A loaded `bluetooth` module cannot be swapped on a running system: `rfcomm` holds a
static reference and never drops to zero. Reboot, or install before the stack is loaded.

## Verifying

```sh
modinfo -n bluetooth                    # should point into updates/
objdump -d --disassemble=l2cap_recv_frame \
        $(modinfo -n bluetooth | sed 's/\.zst$//') | grep -c '\$0x2a0'
```

`0x2a0` is 672. Seeing it proves the patched header actually won over the stock one —
worth checking, because a wrong include order silently produces an unpatched module.

Then simply connect the earbuds:

```sh
bluetoothctl connect AA:BB:CC:DD:EE:FF
pactl list cards short | grep bluez
```

## Rolling back

```sh
sudo dkms remove -m bluetooth-freebuds -v 1.0 --all     # method 2
sudo rm /lib/modules/$(uname -r)/updates/bluetooth.ko.zst   # method 1
sudo depmod -a && reboot
```

The distribution module in `kernel/net/bluetooth/` was never touched, so this is all it
takes.

## Caveats

* **Security.** While the override is active, your Bluetooth stack is the one these
  sources were cut from. Fixes shipped in later kernel updates do **not** reach it. Refresh
  the package from a current `linux-source` every few months.
* **Staleness is silent.** When a new kernel changes an internal API the DKMS build fails
  and the stock module takes over — Bluetooth keeps working, the earbuds quietly stop.
  Check `dkms status` if they ever stop connecting. A real example: sources cut from
  6.8.0-147 do not build against 6.8.0-146 headers, because they call `secs_to_jiffies()`,
  which that release does not have yet.
* **This reopens an amplification vector.** The check exists because an unpaired peer in
  radio range could force 168 echo responses out of a single 681-byte signalling packet.
  Raising the limit restores that exposure. For a laptop the practical risk is low — it
  takes someone within Bluetooth range deliberately doing it — but it is not zero, and it
  should be a decision you make knowingly.
* **This is a workaround, not a fix.** A proper fix has to keep the attack closed. Two
  differences are worth exploiting: the attack happens *before pairing*, while the FreeBuds
  frame arrives *after* `Encryption Change`; and the attack packs 168 commands into one
  packet, while the FreeBuds send exactly one. Bounding commands per packet, or relaxing
  the limit only on encrypted links, would cover both. That argument has gone to the
  Bluetooth maintainers.

## Prebuilt modules

`prebuilt/` holds modules for the exact kernel releases listed there, with checksums in
`SHA256SUMS`. A kernel module is bound to its kernel's exact release string and build
configuration, so these are useful **only** on those releases — on anything else, build
your own with one of the methods above.

## Where this is reported

* Ubuntu kernel bug: [LP#2172088](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2172088) — the actionable one for Ubuntu users.
* BlueZ issue [#2526](https://github.com/bluez/bluez/issues/2526#issuecomment-6374523810)
  — the analysis above, posted on the existing report.
* `btmon` aborting on this system turned out to be a separate bug, filed as
  [bluez/bluez#2704](https://github.com/bluez/bluez/issues/2704).
* A fix can only come from the Bluetooth maintainers; a mail draft for
  `linux-bluetooth@vger.kernel.org` is in
  [docs/reports/linux-bluetooth-mail.md](docs/reports/linux-bluetooth-mail.md).

## Related

* BlueZ issue [#2526](https://github.com/bluez/bluez/issues/2526) — same device, same
  `0x13` disconnect loop, same oversized vendor echo. Closed as stale without a diagnosis.
* Earlier reports that went stale the same way: bluez/bluez#351, #745, #1011, #1646, #1743.

## Licence

The Bluetooth sources and the patch are derived from the Linux kernel and remain
**GPL-2.0-only**. `dkms/bluetooth-freebuds-1.0/` is the complete corresponding source for
the binaries in `prebuilt/`. Everything original here — scripts and documentation — is
also GPL-2.0-only for simplicity.
