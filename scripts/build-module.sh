#!/bin/bash
# Build a patched "bluetooth" kernel module from the distribution kernel source.
#
# Usage: scripts/build-module.sh [kernel-release]      (default: the running kernel)
# Output: build/<kernel-release>/bluetooth.ko.zst
#
# Needs: linux-source-<version>, linux-headers-<kernel-release>, build-essential,
#        flex bison libelf-dev dwarves zstd
set -euo pipefail

KREL="${1:-$(uname -r)}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PATCH="$REPO/patches/0001-l2cap-raise-bredr-signalling-mtu.patch"
OUT="$REPO/build/$KREL"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# "6.8.0-147-generic" -> base "6.8.0", localversion "-147-generic"
BASE="${KREL%%-*}"
LOCALVERSION="-${KREL#*-}"

HDR="/usr/src/linux-headers-$KREL"
CFG="/boot/config-$KREL"
[ -d "$HDR" ] || { echo "missing $HDR (install linux-headers-$KREL)" >&2; exit 1; }
[ -f "$CFG" ] || { echo "missing $CFG" >&2; exit 1; }

TARBALL="$(ls /usr/src/linux-source-"$BASE"*.tar.* 2>/dev/null | head -1 || true)"
[ -n "$TARBALL" ] || { echo "no linux-source tarball in /usr/src (install linux-source-$BASE)" >&2; exit 1; }

echo "== unpacking $TARBALL"
mkdir -p "$WORK/src"
tar -xf "$TARBALL" -C "$WORK/src" --strip-components=1
cd "$WORK/src"

echo "== configuring from $CFG"
cp "$CFG" .config
cp "$HDR/Module.symvers" .
# Only the signing bits are touched. Do NOT disable DEBUG_INFO here: it drags
# DEBUG_INFO_BTF_MODULES with it, which changes sizeof(struct module) and makes
# the kernel refuse the module. See docs/PITFALLS.md.
scripts/config --file .config \
	--disable MODULE_SIG_ALL \
	--disable MODULE_SIG_FORCE \
	--set-str SYSTEM_TRUSTED_KEYS "" \
	--set-str SYSTEM_REVOCATION_KEYS ""

echo "== patching"
patch -p1 < "$PATCH"

echo "== preparing tree"
make LOCALVERSION="$LOCALVERSION" olddefconfig >/dev/null
make LOCALVERSION="$LOCALVERSION" -j"$(nproc)" modules_prepare

# Distribution tarballs carry the upstream version (e.g. 6.8.12) while the
# installed kernel calls itself 6.8.0-NNN-generic. vermagic must match exactly
# or the module will not load.
echo "#define UTS_RELEASE \"$KREL\"" > include/generated/utsrelease.h

echo "== building net/bluetooth"
make LOCALVERSION="$LOCALVERSION" -j"$(nproc)" M=net/bluetooth modules

echo "== sanity checks"
sec() { readelf -SW "$1" | grep -m1 '\.gnu\.linkonce\.this_module ' | awk '{print $6}'; }
STOCK_KO="$WORK/stock.ko"
zstd -dqc "/lib/modules/$KREL/kernel/net/bluetooth/bluetooth.ko.zst" > "$STOCK_KO" 2>/dev/null \
	|| cp "/lib/modules/$KREL/kernel/net/bluetooth/bluetooth.ko" "$STOCK_KO"
NEW_SEC="$(sec net/bluetooth/bluetooth.ko)"; OLD_SEC="$(sec "$STOCK_KO")"
echo "   struct module section: built=0x$NEW_SEC stock=0x$OLD_SEC"
[ "$NEW_SEC" = "$OLD_SEC" ] || { echo "   MISMATCH - the kernel will reject this module" >&2; exit 1; }

VM="$(modinfo -F vermagic net/bluetooth/bluetooth.ko)"
echo "   vermagic: $VM"
case "$VM" in "$KREL "*) ;; *) echo "   vermagic does not match $KREL" >&2; exit 1 ;; esac

if objdump -d --disassemble=l2cap_recv_frame net/bluetooth/bluetooth.ko | grep -q '\$0x2a0'; then
	echo "   patched constant 0x2a0 (672) present"
else
	echo "   patched constant NOT found - the stock header won the include race" >&2
	exit 1
fi

echo "== packaging"
mkdir -p "$OUT"
cp net/bluetooth/bluetooth.ko "$OUT/bluetooth.ko"
strip --strip-debug "$OUT/bluetooth.ko"
zstd -q -f -19 "$OUT/bluetooth.ko" -o "$OUT/bluetooth.ko.zst"
rm -f "$OUT/bluetooth.ko"
( cd "$OUT" && sha256sum bluetooth.ko.zst > SHA256SUMS )

echo
echo "built: $OUT/bluetooth.ko.zst"
echo "install it with: sudo scripts/install-module.sh $KREL"
