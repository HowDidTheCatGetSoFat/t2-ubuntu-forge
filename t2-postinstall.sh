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

# The BCE driver differs per kernel: stock Ubuntu kernel = legacy apple-bce
# (DKMS), t2linux kernel = t2bce MFD stack (deqrocks/t2bce). Only one must
# ever be active, so: blacklist apple-bce (blocks modalias autoload only) and
# a oneshot unit that tries t2bce first, falls back to apple_bce - never both.
# t2bce_vhci ships no modalias, so an explicit load is required anyway.
mkdir -p /etc/modprobe.d /etc/systemd/system
cat > /etc/modprobe.d/t2bce-prefer.conf <<'CONF'
# Prefer the t2bce MFD stack over the legacy apple-bce driver.
# "blacklist" only blocks modalias autoload; the explicit modprobe in
# t2-vhci.service still loads apple_bce on kernels without t2bce.
blacklist apple_bce
CONF
cat > /etc/systemd/system/t2-vhci.service <<'UNIT'
[Unit]
Description=Load T2 BCE VHCI (internal keyboard/trackpad/Touch Bar)
DefaultDependencies=no
After=systemd-modules-load.service
Before=sysinit.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'modprobe t2bce_vhci || modprobe apple_bce'

[Install]
WantedBy=sysinit.target
UNIT
# retire the older both-names approach if present
rm -f /etc/modules-load.d/t2.conf
systemctl daemon-reload
if systemctl enable t2-vhci.service >/dev/null 2>&1; then
	good "t2-vhci.service enabled (t2bce first, apple_bce fallback, never both)"
else
	bad "could not enable t2-vhci.service"
fi

# Load now, without waiting for a reboot
if modprobe t2bce_vhci 2>/dev/null || modprobe apple_bce 2>/dev/null; then
	good "VHCI loaded ($(uname -r))"
else
	note "could not load t2bce_vhci nor apple_bce"
fi

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
