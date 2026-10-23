# Pitfalls

Four traps cost real time while working this out. The build scripts guard against all of
them, but if you do it by hand, these are what will bite you.

## 1. Do not disable DEBUG_INFO to speed the build up

Tempting, because the module links to ~19 MB with debug info. But `DEBUG_INFO_NONE`
disables `DEBUG_INFO_BTF_MODULES` through Kconfig dependencies, and that option is
compiled into `struct module`:

```c
#ifdef CONFIG_DEBUG_INFO_BTF_MODULES
	unsigned int btf_data_size;
	void *btf_data;
#endif
```

The running kernel has the fields, your module does not, and loading fails with:

```
module bluetooth: .gnu.linkonce.this_module section size must match
                  the kernel's built struct module size at run time
```

Strip the debug sections *after* linking instead. Compare the section size against the
stock module before installing — it must be identical:

```sh
readelf -SW bluetooth.ko | grep '\.gnu\.linkonce\.this_module '
```

BTF generation itself is skipped automatically with
`Skipping BTF generation ... due to unavailability of vmlinux`, which is harmless.

## 2. vermagic comes from the tarball, not from your kernel

`linux-source-6.8.0` unpacks as upstream **6.8.12**, while the installed kernel calls
itself **6.8.0-147-generic**. Building naively yields `vermagic: 6.8.12-147-generic` and
the module will not load. Overwrite the generated header after `modules_prepare`:

```sh
echo '#define UTS_RELEASE "6.8.0-147-generic"' > include/generated/utsrelease.h
```

## 3. Include order decides whether the patch does anything

For an out-of-tree build (`M=...`), `LINUXINCLUDE` is placed on the compiler command line
*before* `ccflags-y`, so adding `-I$(src)/include` via `ccflags-y` loses: the stock
`l2cap.h` from `linux-headers` is found first and your patch silently has no effect. The
module builds, loads, and behaves exactly like the stock one. Prepend instead:

```make
LINUXINCLUDE := -I$(src)/include $(LINUXINCLUDE)
```

Always verify the constant actually landed in the binary:

```sh
objdump -d --disassemble=l2cap_recv_frame bluetooth.ko | grep '\$0x2a0'
```

## 4. The bluetooth module cannot be swapped on a running system

Stopping `bluetooth.service` and unloading `btusb`, `bnep`, `rfcomm`, `hidp`, `cmtp` is
not enough. `rfcomm` keeps a static reference count (16 on a stock Ubuntu desktop) that
never drops, so `bluetooth` stays resident:

```
rfcomm      102400  16
bluetooth  1044480  83  btrtl,btmtk,btintel,btbcm,bnep,btusb,rfcomm
```

Install the module and reboot.

## Bonus: btmon may be unusable

On bluez 5.72 as shipped by Ubuntu noble, `btmon` aborts immediately, both to stdout and
with `-w`:

```
*** buffer overflow detected ***: terminated
```

`tcpdump` captures the same data:

```sh
sudo tcpdump -i bluetooth-monitor -s 0 -U -w trace.pcap
```

The link type is `LINKTYPE_BLUETOOTH_LINUX_MONITOR` (254): each record starts with a
**big-endian** 2-byte adapter index and 2-byte opcode, where `0x0002` is an HCI command,
`0x0003` an HCI event, `0x0004` an ACL packet sent and `0x0005` one received. A small
decoder for the signalling channel is in [`tools/l2cap-decode.py`](../tools/l2cap-decode.py).
