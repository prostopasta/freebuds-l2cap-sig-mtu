#!/bin/bash
# Install a module built by build-module.sh into updates/, where depmod prefers
# it over the distribution copy in kernel/. Nothing shipped by the distribution
# is modified, so uninstalling is a single rm.
#
# Usage: sudo scripts/install-module.sh [kernel-release]
set -euo pipefail

KREL="${1:-$(uname -r)}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/build/$KREL/bluetooth.ko.zst"
DEST="/lib/modules/$KREL/updates"

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -f "$SRC" ] || { echo "no module at $SRC - run scripts/build-module.sh $KREL first" >&2; exit 1; }

install -d "$DEST"
install -m 0644 "$SRC" "$DEST/bluetooth.ko.zst"
depmod -a "$KREL"

echo "installed: $(modinfo -k "$KREL" -n bluetooth)"
echo
echo "A loaded bluetooth module cannot be replaced on a running system:"
echo "rfcomm holds a static reference, so the stack never unloads. Reboot."
