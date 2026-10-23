# Prebuilt modules

A kernel module is tied to the exact release string and build configuration of the kernel
it was compiled for. These files load **only** on the kernel release named in the
filename; on anything else `modprobe` will refuse them. On any other kernel, build your
own — `scripts/build-module.sh` or the DKMS package both take a few minutes.

Verify before installing:

```sh
sha256sum -c SHA256SUMS
modinfo -F vermagic bluetooth-<release>.ko.zst   # must match `uname -r`
```

Install:

```sh
sudo install -d /lib/modules/<release>/updates
sudo install -m 0644 bluetooth-<release>.ko.zst /lib/modules/<release>/updates/bluetooth.ko.zst
sudo depmod -a <release>
# then reboot - the bluetooth module cannot be swapped on a running system
```

The complete corresponding source for these binaries is in `dkms/bluetooth-freebuds-1.0/`,
as required by the GPL.
