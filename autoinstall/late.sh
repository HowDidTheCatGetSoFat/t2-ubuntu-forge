#!/bin/bash
# Runs from autoinstall late-commands: in the INSTALLER environment, with the
# freshly installed system mounted at /target.
#
# Does the full T2 post-install:
#   - Wi-Fi/Bluetooth firmware (from payload, or captured from macOS)
#   - kernel parameters
#   - T2 modules at boot
#   - tiny-dfr (Touch Bar) from the .deb shipped in the ISO
#   - i9 power cap (MacBookPro15,1 only)
#
# Log ends up in /var/log/t2-autoinstall.log inside the installed system.

set -uo pipefail

T=/target
LOG="$T/var/log/t2-autoinstall.log"
PARAMS="intel_iommu=on iommu=pt pm_async=off"

mkdir -p "$(dirname "$LOG")" 2>/dev/null
exec > >(tee -a "$LOG") 2>&1

ok=0; bad=0
good() { echo "[ok]    $*"; ok=$((ok+1)); }
fail() { echo "[FAIL]  $*"; bad=$((bad+1)); }

echo "===== t2 late.sh  $(date -u '+%Y-%m-%dT%H:%M:%SZ') ====="

# ---------- locate the payload on the install medium ----------
PAY=""
for d in /cdrom/t2 /media/cdrom/t2 /run/initramfs/cdrom/t2 /isodevice/t2; do
	[ -d "$d" ] && { PAY="$d"; break; }
done
if [ -z "$PAY" ]; then
	PAY=$(find /cdrom /media /mnt /run -maxdepth 4 -type d -name t2 2>/dev/null | head -1)
fi
if [ -z "$PAY" ]; then
	fail "t2/ directory not found on the install medium — cannot continue"
	echo "ok=$ok failed=$bad"
	exit 1
fi
good "payload at $PAY"

# ---------- helper to run inside the installed system ----------
in_target() {
	if command -v curtin >/dev/null 2>&1; then
		curtin in-target -- "$@"
	else
		chroot "$T" "$@"
	fi
}

# ---------- 1. Wi-Fi / Bluetooth firmware ----------
if [ -f "$PAY/firmware.tar" ]; then
	mkdir -p "$T/lib/firmware/brcm"
	if tar -xf "$PAY/firmware.tar" -C "$T/lib/firmware/brcm"; then
		n=$(ls -1 "$T/lib/firmware/brcm" | wc -l | tr -d ' ')
		good "firmware extracted into /lib/firmware/brcm ($n files)"
	else
		fail "could not extract firmware.tar"
	fi
elif in_target sh -c 'command -v get-apple-firmware >/dev/null 2>&1'; then
	# No firmware in the payload: capture it from the macOS install on the
	# internal disk. The t2 ISO ships the apple-firmware-script package and
	# the apfs driver; `get_from_macos` mounts the APFS volume and extracts
	# /usr/share/firmware on its own.
	# (Verified non-interactive, RC=0, on a MacBookPro15,1.)
	# Requires macOS to still be present on the internal disk.
	if in_target get-apple-firmware get_from_macos </dev/null >/dev/null 2>&1; then
		n=$(ls -1 "$T/lib/firmware/brcm" 2>/dev/null | wc -l | tr -d ' ')
		good "firmware captured from macOS on the internal disk ($n files in brcm/)"
	else
		echo "[warn] get_from_macos failed (no macOS on the internal disk?) — Wi-Fi/BT left for post-install"
	fi
else
	echo "[warn] no firmware.tar and no get-apple-firmware — Wi-Fi/BT left for post-install"
fi

# ---------- 2. kernel parameters ----------
G="$T/etc/default/grub"
if [ -f "$G" ]; then
	cp "$G" "$G.pre-t2"
	changed=0
	if ! grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$G"; then
		echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$PARAMS\"" >> "$G"
		changed=1
	else
		for p in $PARAMS; do
			grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=.*$p" "$G" && continue
			sed -i "s|^\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"|\1 $p\"|" "$G"
			changed=1
		done
	fi
	missing=""
	for p in $PARAMS; do
		grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=.*$p" "$G" || missing="$missing $p"
	done
	if [ -n "$missing" ]; then
		fail "these parameters did not stick:$missing"
	else
		good "kernel parameters: $PARAMS"
	fi
	if [ "$changed" = "1" ]; then
		if in_target update-grub >/dev/null 2>&1; then
			good "update-grub ran in the installed system"
		else
			fail "update-grub failed"
		fi
	fi
else
	fail "$G does not exist"
fi

# ---------- 3. T2 modules ----------
mkdir -p "$T/etc/modules-load.d"
# The VHCI module name DEPENDS ON THE KERNEL. Verified with modinfo on the
# real machine, on both kernels:
#
#   stock Ubuntu kernel + DKMS (7.0.0-x-generic) -> apple_bce
#                                                   t2bce_* does NOT exist
#   t2linux patched kernel (7.1.5-1-t2-*)        -> t2bce_vhci (in-tree)
#                                                   apple_bce does NOT exist
#
# The ISO installs the stock kernel, but an `apt full-upgrade` pulls in the
# t2linux kernel and boots it. If the name does not match, the VHCI never
# loads and you end up with NO internal keyboard or trackpad.
#
# Both names are listed: whichever exists gets loaded. systemd logs the
# missing one and the unit still ends in success (verified).
if cat > "$T/etc/modules-load.d/t2.conf" <<'EOF'
# T2 VHCI: exposes the internal keyboard, trackpad and Touch Bar.
# It does NOT autoload; it must be requested explicitly.
# The module name depends on the kernel; both are listed, whichever exists loads.
t2bce_vhci
apple_bce
EOF
then
	good "T2 VHCI in /etc/modules-load.d/t2.conf (t2bce_vhci + apple_bce)"
else
	fail "could not write modules-load.d/t2.conf"
fi

# ---------- 4. tiny-dfr (Touch Bar) ----------
deb=$(ls "$PAY"/tiny-dfr_*.deb 2>/dev/null | head -1)
if [ -n "$deb" ]; then
	cp "$deb" "$T/tmp/" && \
	if in_target dpkg -i "/tmp/$(basename "$deb")" >/dev/null 2>&1; then
		good "tiny-dfr installed (Esc and F-keys on the Touch Bar)"
	else
		fail "dpkg -i of tiny-dfr failed — install it later with: sudo apt install tiny-dfr"
	fi
	rm -f "$T/tmp/$(basename "$deb")"
else
	echo "[warn] no tiny-dfr .deb in the payload — Touch Bar left for post-install (needs network)"
fi

# ---------- 5. i9 power cap (MacBookPro15,1 only) ----------
# PL1=45W measured as optimal ON THIS MODEL (i9-8950HK, 2018 15" chassis).
# On other T2 models the value would be wrong (it could even RAISE the limit
# of a smaller chip), hence the strict DMI guard.
if [ -d "$PAY/powercap" ]; then
	model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "?")
	if [ "$model" = "MacBookPro15,1" ]; then
		if cp "$PAY/powercap/t2-powercap" "$T/etc/default/t2-powercap" \
		   && install -m 755 "$PAY/powercap/t2-powercap.sh" "$T/usr/local/sbin/t2-powercap.sh" \
		   && cp "$PAY/powercap/t2-powercap.service" "$T/etc/systemd/system/t2-powercap.service" \
		   && in_target systemctl enable t2-powercap.service >/dev/null 2>&1; then
			good "PL1=45W power cap installed and enabled (i9 anti-throttling)"
		else
			fail "could not install/enable t2-powercap"
		fi
	else
		echo "[warn] powercap: model $model != MacBookPro15,1 — skipped (the 45W value is specific to the 15\" i9)"
	fi
fi

# ---------- summary ----------
echo
echo "===== summary: ok=$ok failed=$bad ====="
echo "After rebooting, verify with:"
echo "  sudo journalctl -k --grep=brcmfmac"
echo "  cat /proc/cmdline"
echo "  lsmod | grep -E 'apple|t2'"
echo "  cat /var/log/t2-autoinstall.log"

# Do not abort the installation on a partial failure: the system still boots
# and everything here is fixable afterwards. Exit 0 on purpose.
exit 0
