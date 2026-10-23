Target: comment on https://github.com/bluez/bluez/issues/2526
Posted as: https://github.com/bluez/bluez/issues/2526#issuecomment-6374523810

---

This is not a BlueZ bug — it is a kernel-side regression, and the oversized vendor echo
that the report mentions and sets aside is in fact the trigger.

### What the earbuds are doing

FreeBuds 3 push battery telemetry as an L2CAP **Echo Request on the signalling channel**.
The frame is 68 bytes in total (4-byte command header + 64-byte payload):

```
<--  L2CAP Echo Request    ident=129 len=64
     payload: 3f 04 03 01 38 00 "AT+HUAWEIBATTERY=6,2,100,3,0,4,100,5,0,6,35,7,0\r" 00...
-->  L2CAP Command Reject  reason=1 (Signalling MTU exceeded) max_mtu=48
```

### Why that is now fatal

`l2cap_sig_channel()` gained this, in commit *"Bluetooth: L2CAP: reject BR/EDR signaling
packets over MTUsig"* (Michael Bommarito, author date 2026-09-03):

```c
	if (skb->len > L2CAP_SIG_MTU) {
		u8 ident = skb->data[1];

		BT_DBG("signaling packet exceeds MTU: %u > %u",
		       skb->len, L2CAP_SIG_MTU);
		l2cap_sig_send_mtu_rej(conn, ident);
		goto drop;
	}
```

with `L2CAP_SIG_MTU` defined as 48. The whole packet is discarded, so the Echo Request
never reaches `case L2CAP_ECHO_REQ:` and no Echo Response is sent. Previously the kernel
was lenient and answered it.

The earbuds wait for that response. They do open AVDTP (PSM 0x19) and AVCTP (PSM 0x17),
the host accepts both and sends Config Requests — and then nothing comes back and the
remote tears the ACL down about 160 ms later:

```
Connect Complete      status=0x00
Link Key Request
Auth Complete         status=0x00
Encryption Change     status=0x00 enabled=1
...
Disconnect Complete   status=0x00 reason=0x13 (Remote User Terminated)
```

Crypto is fine throughout; the device simply gives up. The cycle then repeats every 3–4
seconds indefinitely — 36 attempts over four minutes in my case, never converging.

### Confirmation

Raising `L2CAP_SIG_MTU` to 672 and rebuilding only `bluetooth.ko` makes the earbuds
connect on the first attempt. A2DP (SBC) comes up immediately and has been stable since.
Nothing else changed.

```diff
-#define L2CAP_SIG_MTU			48	/* BR/EDR signaling MTU */
+#define L2CAP_SIG_MTU			672	/* BR/EDR signaling MTU */
```

### Environment

Ubuntu 24.04, kernel 6.8.0-147-generic, BlueZ 5.72, Intel AX201 (`ibt-17-16-1`, FW
155-35.23), PipeWire 1.0.5. A JBL TUNE770NC on the same host connects and plays normally,
so the host stack is healthy. Vanilla 6.8, 6.12 and 6.15 do not contain the check —
`L2CAP_REJ_MTU_EXCEEDED` is defined there but never emitted — so this is specific to trees
that carry the commit above.

### On the fix

Per Bluetooth Core 5.4, Vol 3, Part A §4 the device is out of spec: MTUsig is 48 octets
and §4.1 does say an over-MTU packet should be discarded. So the commit is defensible as
written. But discarding the entire packet is a behaviour change that breaks working
hardware, and the reject alone gives the peer nothing to act on. Either continuing to
process commands that fit, or answering `L2CAP_ECHO_REQ` regardless of size, would keep
interop while still being conservative.

### Repro tooling

`btmon` from bluez 5.72 aborts immediately on this system (`*** buffer overflow detected
***`), both to stdout and with `-w`, so the traces above were captured with
`tcpdump -i bluetooth-monitor` and decoded with a small script. That script, the patch,
and build instructions for both a one-off module and a DKMS package are here:

https://github.com/prostopasta/freebuds-l2cap-sig-mtu

Happy to provide full `bluetoothd -n -d` logs correlated with the captures if that helps.
