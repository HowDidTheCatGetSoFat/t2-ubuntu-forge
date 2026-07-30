#!/usr/bin/env bash
# Builds an Ubuntu installer ISO for T2-chip MacBooks, based on the t2linux
# patched ISO, with an automated post-install (late-commands).
#
# The installer ASKS for username, password and hostname (subiquity's normal
# identity screen) and partitioning is interactive. Everything else runs
# unattended: openssh-server, kernel parameters, T2 modules, tiny-dfr, and
# the i9 power cap (only when the target model is MacBookPro15,1).
#
# Wi-Fi/BT firmware: if --firmware is not given, the installer captures it by
# itself from the macOS install on the internal disk (get_from_macos). You
# only need --firmware when the target Mac no longer has macOS.
#
# Runs on macOS or Linux. Requires: bash, curl, xorriso, shasum or sha256sum.
#
# Usage:
#   ./build-t2-iso.sh [options]
#
# Options:
#   --base-iso PATH     already-downloaded t2linux ISO (otherwise fetched
#                       from GitHub and sha256-verified)
#   --firmware PATH     firmware.tar for THAT Mac (generated with
#                       firmware.sh create_archive on its macOS). Optional:
#                       without it the installer self-captures from macOS.
#   --disk-serial SER   udev ID_SERIAL of the target disk, as a safety net
#                       for partitioning. NOTE: this is the serial as seen by
#                       LINUX (udevadm info), NOT the one macOS shows - they
#                       differ on USB enclosures. Without it there is no
#                       match and partitioning is interactive only.
#   --release TAG       t2linux/T2-Ubuntu release        [v7.0.9-1]
#   --flavor F          flavor-version                   [ubuntu-26.04]
#   --out PATH          output ISO                       [./<flavor>-t2-autoinstall.iso]
#
# Examples:
#   ./build-t2-iso.sh                                   # generic
#   ./build-t2-iso.sh --firmware fw.tar --disk-serial 'SanDisk_SD9SN8W512G_185068474901'

set -euo pipefail

RELEASE="v7.0.9-1"
FLAVOR="ubuntu-26.04"
BASE_ISO=""
FIRMWARE=""
DISK_SERIAL=""
OUT=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TINYDFR_REPO="https://github.com/AdityaGarg8/t2-ubuntu-repo/releases/download"

while [ $# -gt 0 ]; do
	case "$1" in
		--base-iso)    BASE_ISO="$2"; shift 2 ;;
		--firmware)    FIRMWARE="$2"; shift 2 ;;
		--disk-serial) DISK_SERIAL="$2"; shift 2 ;;
		--release)     RELEASE="$2"; shift 2 ;;
		--flavor)      FLAVOR="$2"; shift 2 ;;
		--out)         OUT="$2"; shift 2 ;;
		-h|--help)     sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "unknown option: $1 (see --help)" >&2; exit 1 ;;
	esac
done

command -v xorriso >/dev/null || { echo "missing xorriso (brew install xorriso / apt install xorriso)" >&2; exit 1; }
command -v curl >/dev/null || { echo "missing curl" >&2; exit 1; }
if command -v shasum >/dev/null; then SHA() { shasum -a 256 "$@"; }
elif command -v sha256sum >/dev/null; then SHA() { sha256sum "$@"; }
else echo "missing shasum/sha256sum" >&2; exit 1; fi

[ -n "$OUT" ] || OUT="./${FLAVOR}-t2-autoinstall.iso"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== [1/5] base ISO =="
if [ -n "$BASE_ISO" ]; then
	[ -f "$BASE_ISO" ] || { echo "$BASE_ISO does not exist" >&2; exit 1; }
	echo "  using $BASE_ISO"
else
	REL_URL="https://github.com/t2linux/T2-Ubuntu/releases/download/${RELEASE}"
	# the exact name (with codename) comes from the checksum asset
	curl -fsSL "$REL_URL/sha256-${FLAVOR}" -o "$WORK/sha" \
		|| { echo "could not fetch sha256-${FLAVOR} from release ${RELEASE}" >&2; exit 1; }
	ISO_NAME="$(awk '{print $2}' "$WORK/sha" | xargs basename)"
	echo "  downloading ${ISO_NAME} (split parts)..."
	i=0
	while :; do
		part=$(printf '%s.%02d' "$ISO_NAME" "$i")
		curl -fSL --retry 3 -o "$WORK/$part" "$REL_URL/$part" 2>/dev/null || break
		echo "    $part ok"
		i=$((i+1))
	done
	[ "$i" -gt 0 ] || { echo "no parts downloaded — wrong release/flavor?" >&2; exit 1; }
	cat "$WORK/${ISO_NAME}".?? > "$WORK/base.iso"
	BASE_ISO="$WORK/base.iso"
	echo "  verifying sha256..."
	want="$(awk '{print $1}' "$WORK/sha")"
	got="$(SHA "$BASE_ISO" | awk '{print $1}')"
	[ "$want" = "$got" ] || { echo "SHA256 MISMATCH: $got != $want" >&2; exit 1; }
	echo "  sha256 OK"
fi

echo "== [2/5] tiny-dfr (Touch Bar, for offline install) =="
CODENAME="$(basename "$(awk '{print $2}' "$WORK/sha" 2>/dev/null || echo "$BASE_ISO")" \
	| sed -n 's/.*-t2-\([a-z]*\)\.iso.*/\1/p')"
[ -n "$CODENAME" ] || CODENAME="resolute"
deb_file="$(curl -fsSL "$TINYDFR_REPO/$CODENAME/Packages" \
	| awk '/^Package: tiny-dfr$/,/^$/' | awk '/^Filename:/{print $2}' | head -1 | sed 's|^\./||')"
if [ -n "$deb_file" ]; then
	curl -fsSL -o "$WORK/$deb_file" "$TINYDFR_REPO/$CODENAME/$deb_file"
	echo "  $deb_file"
else
	echo "  [warn] tiny-dfr not found in the $CODENAME repo — Touch Bar will need post-install with network"
fi

echo "== [3/5] payload =="
ST="$WORK/stage"; mkdir -p "$ST/t2/powercap"
cp "$SCRIPT_DIR/autoinstall/late.sh" "$ST/t2/late.sh"
cp "$SCRIPT_DIR/powercap/t2-powercap" "$SCRIPT_DIR/powercap/t2-powercap.sh" \
   "$SCRIPT_DIR/powercap/t2-powercap.service" "$ST/t2/powercap/"
[ -n "$deb_file" ] && cp "$WORK/$deb_file" "$ST/t2/"
if [ -n "$FIRMWARE" ]; then
	[ -f "$FIRMWARE" ] || { echo "$FIRMWARE does not exist" >&2; exit 1; }
	cp "$FIRMWARE" "$ST/t2/firmware.tar"
	echo "  firmware.tar included ($(du -h "$FIRMWARE" | cut -f1 | tr -d ' '))"
else
	echo "  [note] no --firmware: the installer will capture it by itself from the"
	echo "         macOS install on the internal disk (get_from_macos). --firmware is"
	echo "         only needed when the target Mac no longer has macOS."
fi

# autoinstall.yaml: identity and partitioning INTERACTIVE, the rest automated.
{
	cat <<-'YAML'
	# Generated by build-t2-iso.sh — carries NO username or password: subiquity
	# asks for them on its identity screen (interactive-sections).
	version: 1
	interactive-sections:
	  - identity
	  - storage
	refresh-installer:
	  update: false
	locale: en_US.UTF-8
	keyboard:
	  layout: us
	source:
	  id: ubuntu-desktop-minimal
	  search_drivers: false
	ssh:
	  install-server: true
	  allow-pw: true
	network:
	  version: 2
	YAML
	if [ -n "$DISK_SERIAL" ]; then
		cat <<-YAML
		# Safety net: should this section ever run non-interactively, subiquity
		# can only touch the disk with this udev ID_SERIAL; if it cannot find
		# it, the install ABORTS (it does not fall back to another disk).
		storage:
		  layout:
		    name: direct
		    match:
		      serial: '${DISK_SERIAL}'
		YAML
	else
		cat <<-'YAML'
		storage:
		  layout:
		    name: direct
		YAML
	fi
	cat <<-'YAML'
	late-commands:
	  - bash /cdrom/t2/late.sh
	YAML
} > "$ST/autoinstall.yaml"

echo "== [4/5] building ISO =="
rm -f "$OUT"
xorriso -indev "$BASE_ISO" -outdev "$OUT" \
	-boot_image any replay \
	-map "$ST/autoinstall.yaml" /autoinstall.yaml \
	-map "$ST/t2" /t2 \
	2>&1 | grep -E 'Replayed|completed successfully|FAILURE|SORRY' || true
[ -f "$OUT" ] || { echo "xorriso did not produce the ISO" >&2; exit 1; }

echo "== [5/5] verifying =="
# ISO9660 PVD at offset 32768
[ "$(dd if="$OUT" bs=1 skip=32769 count=5 2>/dev/null)" = "CD001" ] \
	|| { echo "the ISO has no valid PVD" >&2; exit 1; }
# expected content present
xorriso -indev "$OUT" -find /t2 -type f 2>/dev/null | sed 's/^/  /'
xorriso -indev "$OUT" -find /autoinstall.yaml 2>/dev/null >/dev/null \
	|| { echo "autoinstall.yaml missing inside the ISO" >&2; exit 1; }

echo
echo "DONE: $OUT"
SHA "$OUT"
cat <<EOF

Next steps:
  1. Write to a USB stick (8GB+, everything on it is erased):
       diskutil list                      # identify the stick (macOS)
       sudo dd if=$OUT of=/dev/rdiskN bs=4m
  2. On the target T2 Mac: Secure Boot to "No Security" + allow external
     boot (Cmd+R -> Startup Security Utility), then boot holding Option/Alt.
  3. The installer asks for user/password/hostname and the target disk.
     Everything else runs unattended. Final log: /var/log/t2-autoinstall.log
EOF
