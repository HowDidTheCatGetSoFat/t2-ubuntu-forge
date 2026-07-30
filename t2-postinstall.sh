#!/usr/bin/env bash
# Post-install for Ubuntu 26.04 on a MacBook Pro 2018 15" (MacBookPro15,1 / T2).
# Idempotent: safe to run multiple times.
#
#   sudo bash -c 'mount /dev/nvme0n1p1 /mnt; bash /mnt/t2-postinstall.sh'
#
# Copies itself to /tmp and re-executes from there, so it can release and
# unmount the EFI partition (firmware.sh needs to mount it on its own).
#
# Does: Wi-Fi/BT firmware, kernel parameters, T2 modules, tiny-dfr.

set -uo pipefail

ESP=/dev/nvme0n1p1
PARAMS=(intel_iommu=on iommu=pt pm_async=off)
GRUBF=/etc/default/grub
WORK=/tmp/t2-postinstall.sh

ok=0; warn=0; fail=0
say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
good() { printf '  [ok] %s\n' "$*"; ok=$((ok+1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; fail=$((fail+1)); }
note() { printf '  [warn] %s\n' "$*"; warn=$((warn+1)); }

[ "$(id -u)" -eq 0 ] || { echo "Run this with sudo." >&2; exit 1; }

# ---------- relocate to /tmp ----------
# If running from the ESP, copy self and re-exec so the partition is free
# to be unmounted below.
SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
if [ "$SELF" != "$WORK" ]; then
	cp "$SELF" "$WORK" || { echo "could not copy myself to $WORK" >&2; exit 1; }
	# Grab firmware.sh before losing access to the ESP
	src=$(dirname "$SELF")
	[ -f "$src/firmware.sh" ] && cp "$src/firmware.sh" /tmp/firmware.sh
	exec bash "$WORK" "$@"
fi

# ---------- guards ----------
say "Pre-checks"

rootfs=$(findmnt -no FSTYPE / 2>/dev/null || echo unknown)
case "$rootfs" in
	squashfs|overlay|tmpfs)
		echo "ERROR: you are in the LIVE session (root on $rootfs)." >&2
		echo "This script runs AFTER installing, on the installed system." >&2
		exit 1 ;;
esac
good "installed system (root on $rootfs), not live"

model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "?")
if [ "$model" = "MacBookPro15,1" ]; then
	good "model $model"
else
	note "detected model: $model (expected MacBookPro15,1) — continuing anyway"
fi

# ---------- 1. Wi-Fi and Bluetooth ----------
say "1/4  Wi-Fi and Bluetooth firmware"

if ls /lib/firmware/brcm/brcmfmac4364*.bin >/dev/null 2>&1; then
	good "BCM4364 firmware already in /lib/firmware/brcm — nothing to do"
elif [ ! -b "$ESP" ]; then
	bad "$ESP does not exist (the internal disk's ESP). Check 'lsblk'"
else
	# Get firmware.sh: we may already have it from the relocation step
	if [ ! -f /tmp/firmware.sh ]; then
		tmp=$(mktemp -d)
		if mount -o ro "$ESP" "$tmp" 2>/dev/null; then
			[ -f "$tmp/firmware.sh" ] && cp "$tmp/firmware.sh" /tmp/firmware.sh
			umount "$tmp"
		fi
		rmdir "$tmp" 2>/dev/null
	fi

	if [ ! -f /tmp/firmware.sh ]; then
		bad "firmware.sh not found on the ESP. Redo the macOS step."
	else
		# firmware.sh mounts the ESP on its own: release it first
		while mp=$(findmnt -no TARGET --source "$ESP" 2>/dev/null | head -1); [ -n "$mp" ]; do
			umount "$mp" 2>/dev/null || break
		done
		# -i = non-interactive; keeps the copy on the ESP for the future
		if bash /tmp/firmware.sh -i get_from_efi; then
			good "firmware installed into /lib/firmware/brcm"
		else
			bad "firmware.sh failed — run by hand: bash /tmp/firmware.sh get_from_efi"
		fi
	fi
fi

# ---------- 2. kernel parameters ----------
say "2/4  Kernel parameters"

if [ ! -f "$GRUBF" ]; then
	bad "$GRUBF does not exist"
else
	[ -f "$GRUBF.pre-t2" ] || cp "$GRUBF" "$GRUBF.pre-t2"
	changed=0
	if ! grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUBF"; then
		printf 'GRUB_CMDLINE_LINUX_DEFAULT="%s"\n' "${PARAMS[*]}" >> "$GRUBF"
		good "GRUB_CMDLINE_LINUX_DEFAULT line created with: ${PARAMS[*]}"
		changed=1
	else
		for p in "${PARAMS[@]}"; do
			if grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=.*${p}" "$GRUBF"; then
				good "$p already present"
			else
				sed -i "s|^\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"|\1 ${p}\"|" "$GRUBF"
				if grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=.*${p}" "$GRUBF"; then
					good "$p added"; changed=1
				else
					bad "could not add $p — edit $GRUBF by hand"
				fi
			fi
		done
	fi
	if [ "$changed" = "1" ]; then
		if update-grub >/dev/null 2>&1; then
			good "update-grub ran"
		else
			bad "update-grub failed — run it by hand and check the error"
		fi
	fi
	printf '  final line: %s\n' "$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUBF")"
fi

# ---------- 3. T2 modules ----------
say "3/4  T2 modules at boot"

# The VHCI module name DEPENDS ON THE KERNEL. Verified with modinfo:
#   stock Ubuntu kernel + DKMS (7.0.0-x-generic) -> apple_bce
#   t2linux patched kernel     (7.1.5-1-t2-*)    -> t2bce_vhci (in-tree)
# On each kernel, the other name does NOT exist. If it does not match, you
# lose the internal keyboard and trackpad. Both names are listed: whichever
# exists gets loaded.
mkdir -p /etc/modules-load.d
if grep -qs '^t2bce_vhci$' /etc/modules-load.d/t2.conf \
   && grep -qs '^apple_bce$' /etc/modules-load.d/t2.conf; then
	good "modules-load.d/t2.conf already had both names"
else
	if cat > /etc/modules-load.d/t2.conf <<'EOF'
# T2 VHCI: exposes the internal keyboard, trackpad and Touch Bar.
# It does NOT autoload (no modalias), so explicit load is the canonical path,
# matching the t2linux wiki. Listing t2bce_vhci brings up the whole MFD stack:
# modprobe resolves t2bce_core+t2bce_dma via depends, and t2bce_audio binds on
# its own PCI alias (106b:1803). apple_bce is the fallback for the stock
# Ubuntu kernel, where the BCE driver is the old DKMS module and t2bce_* does
# not exist. Only one of the two exists per kernel; the missing one is logged
# by systemd-modules-load and ignored. If both ever coexist for one kernel,
# t2bce is listed first and upstream (deqrocks/t2bce) recommends blacklisting
# apple-bce.
t2bce_vhci
apple_bce
EOF
	then
		good "VHCI configured (t2bce_vhci + apple_bce)"
	else
		bad "could not write /etc/modules-load.d/t2.conf"
	fi
fi

# Load it now, without waiting for a reboot
for m in t2bce_vhci apple_bce; do
	modinfo "$m" >/dev/null 2>&1 || continue
	modprobe "$m" 2>/dev/null && good "$m loaded ($(uname -r))" \
		|| note "modprobe $m failed"
done

if grep -qiE 'Internal Keyboard|Trackpad' /proc/bus/input/devices 2>/dev/null; then
	good "internal keyboard/trackpad present"
else
	note "internal keyboard/trackpad NOT visible in /proc/bus/input/devices"
	note "they do not work without the VHCI loaded — keep a USB keyboard handy"
fi

# ---------- 4. Touch Bar ----------
say "4/4  Touch Bar (tiny-dfr)"

if dpkg -s tiny-dfr >/dev/null 2>&1; then
	good "tiny-dfr already installed"
elif ! ping -c1 -W3 archive.ubuntu.com >/dev/null 2>&1 \
     && ! ping -c1 -W3 8.8.8.8 >/dev/null 2>&1; then
	note "no network — skipped. Reboot, connect to Wi-Fi and run this again."
else
	apt-get update -qq >/dev/null 2>&1
	if apt-get install -y tiny-dfr >/dev/null 2>&1; then
		good "tiny-dfr installed"
	else
		note "tiny-dfr could not be installed: the t2-ubuntu-repo is missing."
		note "See https://wiki.t2linux.org/guides/postinstall/ — without it there is no Esc or F-keys."
	fi
fi

# ---------- summary ----------
say "Summary"
printf '  ok: %d   warnings: %d   failures: %d\n' "$ok" "$warn" "$fail"
cat <<'EOF'

  Reboot, then verify:

    sudo journalctl -k --grep=brcmfmac     # Wi-Fi: firmware loaded, iface wlp3s0
    cat /proc/cmdline                      # the 3 parameters present
    lsmod | grep -E 'apple|t2'             # VHCI modules

  If the Touch Bar step was skipped, run this again once you have network.
EOF
[ "$fail" -eq 0 ] || exit 1
