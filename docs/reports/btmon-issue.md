Target: new issue at https://github.com/bluez/bluez/issues
Filed as: https://github.com/bluez/bluez/issues/2704

Title: btmon: SIGABRT "buffer overflow detected" in print_packet() when the output is too narrow

---

`btmon` aborts immediately on every live capture on this system, before printing a single
line:

```
$ sudo btmon
*** buffer overflow detected ***: terminated
Aborted (core dumped)
```

It is not specific to live capture permissions — `btmon` without root exits cleanly with
`Failed to bind channel: Operation not permitted`. With root it dies as soon as the first
packets arrive.

### It depends on the output width

```
sudo btmon -C 60    -> *** buffer overflow detected ***
sudo btmon -C 80    -> *** buffer overflow detected ***
sudo btmon -C 100   -> works
sudo btmon -C 120   -> works
sudo btmon -C 250   -> works
```

80 is what you get by default when stdout is not a terminal, and it is a perfectly common
terminal width, so on this machine `btmon` is simply unusable.

### Where it comes from

`print_packet()` in `monitor/packet.c`:

```c
	char line[256], ts_str[96], pid_str[140];
	...
	if (text) {
		int extra_len = extra ? strlen(extra) : 0;
		int max_len = col - len - extra_len - ts_len - 3;

		n = snprintf(line + pos, max_len + 1, "%s%s",
						label ? ": " : "", text);
```

`max_len` is derived from the output width minus everything already accounted for. It is
never clamped, so when the prefix is long relative to `col` it goes negative, and
`max_len + 1` is passed to `snprintf()` as a `size_t`. With `_FORTIFY_SOURCE` enabled —
the default on Ubuntu — `__snprintf_chk()` sees a size far larger than the space left in
`line[256]` and aborts the process. A large `col` is a problem for the same reason:
`max_len + 1` can exceed `sizeof(line) - pos` even when it is positive.

### Why only live captures

Reading the very same packets back from a file is fine:

```
$ btmon -r trace.btsnoop
Bluetooth monitor ver 5.72
= Note: Linux version 6.8.0-147-generic (x86_64)                       0.448481
= New Index: AA:BB:CC:DD:EE:FF (Primary,USB,hci0)               [hci0] 0.448496
@ RAW Open: <client> (privileged) version 2.22         {0x0003} [hci0] 0.448502
@ MGMT Open: bluetoothd (privileged) version 1.22             {0x0001} 0.448507
```

In live mode the monitor socket supplies `SCM_CREDENTIALS`, so `print_packet()` takes the
`cred && cred->pid` branch and prefixes the line with `pid_str` (up to 140 bytes) from
`cred_pid()`. That inflates `len`, `max_len` goes negative at 80 columns, and the process
dies. With `-r` there are no credentials, the prefix is short, and 80 columns are enough.

The same reasoning explains why `-i <index>` avoids the crash: index filtering clears
`PACKET_FILTER_SHOW_INDEX`, `ts_len` shrinks, and `max_len` stays positive.

In my case the long prefix comes from a privileged RAW client (a management agent) whose
`comm` is 13 characters; strace shows the abort immediately after the `CTRL_OPEN` packet
announcing it is read:

```
recvmsg(7, {... iov_base="\16\0\0\0\36\0" ...
            iov_base="\3\0\0\0\0\0\2\26\0\1\0\0\0\20<client>\0\0\0" ...}) = ...
writev(2, [{"*** "}, {"buffer overflow detected"}, {" ***: terminated\n"}], 3) = 45
--- SIGABRT {si_signo=SIGABRT, si_code=SI_TKILL} ---
```

Any sufficiently long process name will do; nothing about that packet is malformed.

### Suggested fix

Clamp `max_len` to what `line` can actually hold, and to zero at the bottom:

```c
		int max_len = col - len - extra_len - ts_len - 3;

		if (max_len > (int) sizeof(line) - pos - 1)
			max_len = sizeof(line) - pos - 1;
		if (max_len < 0)
			max_len = 0;
```

The `line[pos + max_len - 1]` truncation fixups just below also need `max_len >= 3` to be
safe.

### Workarounds

* `btmon -C 120` or wider when stdout is not a terminal;
* `btmon -i <index>`;
* `tcpdump -i bluetooth-monitor -s 0 -U -w trace.pcap` and decode separately.

### Environment

* Ubuntu 24.04, bluez 5.72-0ubuntu5.8, glibc 2.39
* kernel 6.8.0-147-generic, x86_64
* reproduced on every invocation, 100% of the time

Found while debugging an unrelated A2DP problem, where `btmon` being unusable cost a fair
amount of time: https://github.com/prostopasta/freebuds-l2cap-sig-mtu
