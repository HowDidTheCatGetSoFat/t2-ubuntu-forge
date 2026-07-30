# t2-ubuntu-forge

**Forge bootable, hands-off Ubuntu installers for T2 MacBooks — Wi-Fi, Touch
Bar and i9 unthrottling included.**

One script takes the excellent [t2linux](https://t2linux.org) patched Ubuntu
ISO and turns it into an installer that does almost everything by itself. You
answer exactly two things — *who are you* and *which disk* — and boot into an
Ubuntu where the internal keyboard, trackpad, Wi-Fi, Bluetooth, audio and
Touch Bar all work.

```sh
./build-t2-iso.sh
# write the resulting ISO to a USB stick, boot the Mac holding Option/Alt
```

## What the installer automates

| Step | How |
|---|---|
| Wi-Fi/Bluetooth firmware | **captured automatically from the macOS install on the internal disk** during installation (`get-apple-firmware get_from_macos`, using the apfs driver the t2linux ISO already ships. No prior macOS-side step needed.) |
| Kernel parameters | `intel_iommu=on iommu=pt pm_async=off` |
| T2 VHCI modules at boot | writes **both** `t2bce_vhci` and `apple_bce` to `modules-load.d` — see [the kernel gotcha](#gotcha-1-the-vhci-module-name-depends-on-the-kernel) |
| Touch Bar (Esc / F-keys) | `tiny-dfr` `.deb` bundled in the ISO, installed offline |
| SSH | `openssh-server` installed offline from the ISO pool |
| i9 anti-throttling | PL1 power cap service, installed **only** when the target is a `MacBookPro15,1` (see [measurements](#the-i9-throttling-study)) |
| Identity & partitioning | **interactive on purpose** — subiquity asks for user/password/hostname, and you pick the target disk (the one irreversible step) |

The whole install is **offline**: no network needed until you log in, and by
then Wi-Fi already works.

A post-install log with per-step ok/fail lands in
`/var/log/t2-autoinstall.log` on the installed system.

## Usage

```sh
./build-t2-iso.sh [options]

--base-iso PATH     already-downloaded t2linux ISO (otherwise fetched from
                    GitHub and sha256-verified)
--firmware PATH     firmware.tar for the target Mac. Only needed if the Mac
                    no longer has macOS on the internal disk — otherwise the
                    installer captures the firmware by itself.
--disk-serial SER   udev ID_SERIAL of the target disk, as a partitioning
                    safety net: if the storage step ever ran non-interactively,
                    subiquity could only touch this disk, and aborts if it is
                    absent. NOTE: use the serial Linux sees (udevadm info),
                    NOT the one macOS shows — they differ on USB enclosures.
--release TAG       t2linux/T2-Ubuntu release        [v7.0.9-1]
--flavor F          flavor-version                   [ubuntu-26.04]
--out PATH          output ISO
```

Requirements: `bash`, `curl`, `xorriso`, `shasum`/`sha256sum`. Runs on macOS
or Linux.

On the target Mac (once): boot into Recovery (Cmd+R) → Startup Security
Utility → Secure Boot to **No Security**, allow **external boot**.

## Two gotchas this repo exists to document

### Gotcha 1: the VHCI module name depends on the kernel

The internal keyboard/trackpad go through the T2's Buffer Copy Engine, whose
VHCI module **does not autoload** — and its *name changes between kernels*
(verified with `modinfo` on both):

| Kernel | VHCI module | the other name |
|---|---|---|
| stock Ubuntu + DKMS (`7.0.0-x-generic`, what the ISO installs) | `apple_bce` | `t2bce_*` does not exist |
| t2linux patched (`7.1.5-1-t2-*`, what `apt full-upgrade` brings in) | `t2bce_vhci` (in-tree) | `apple_bce` does not exist |

If `/etc/modules-load.d/` names only one of them, a kernel upgrade silently
boots you into a machine **with no internal keyboard or trackpad**. This
installer writes both names; whichever exists gets loaded and
`systemd-modules-load` still ends in success (verified).

### Gotcha 2: macOS and Linux report different serials for USB disks

For a disk in a USB enclosure, macOS shows the enclosure's serial while udev's
`ID_SERIAL` (what subiquity's storage `match:` uses) is the inner disk's. A
`match: serial:` taken from macOS will never match — the install aborts (which
is at least fail-safe). Take the serial from
`udevadm info --query=property --name=/dev/sdX | grep ID_SERIAL` on Linux.

## The i9 throttling study

The 2018 15" MacBook Pro's i9-8950HK is famous for throttling. Under Linux the
firmware defaults make it **worse** than macOS: PL1 comes up as 100 W with a
~28 s averaging window — effectively unlimited — so the only governor left is
temperature, and the SMC's **BD PROCHOT** (asserted by the VRM, not the die).

Measured on a `MacBookPro15,1` (i9-8950HK, 32 GB), Ubuntu 26.04, t2linux
kernel `7.1.5-1-t2-resolute`. Method: `stress-ng` bogo-ops/s (delivered work,
not MHz), real power via RAPL `energy_uj` deltas, throttle attribution via the
perf-limit-reasons MSR (`0x64F`), 3 reps × 60 s per config, cooldown to 62 °C
between runs, `thermald` stopped during the sweep. Sweep script and raw CSVs
in [`bench/`](bench/).

### Without mitigation, the failure mode is sawtooth PROCHOT

At firmware defaults the package hits 100 °C within seconds, then **BD
PROCHOT pins all cores at 799 MHz while the die cools down to ~73 °C** — the
assertion comes from the VRM, not the CPU sensor. The result oscillates
between 3500 and 800 MHz.

### Config sweep (stress-ng `matrixprod`, heavy FP/vector)

| Config | bogo-ops/s | vs base | pkg W | °C | PROCHOT time |
|---|---|---|---|---|---|
| firmware defaults (PL1 100 W) | 5903 ±94 | — | 47.0 | 95 | 19 % |
| BD PROCHOT disabled only | **6745** ±115 | **+14.3 %** | 50.3 | **100** | 0 % |
| PL1 = 55 W | 6279 ±41 | +6.4 % | 49.0 | 96 | 13 % |
| **PL1 = 45 W** | **6485 ±13** | **+9.8 %** | 45.4 | 93 | **0 %** |
| PL1 = 40 W | 6087 ±100 | +3.1 % | 40.3 | 93 | 0 % |
| PL1 = 35 W | 5865 ±44 | −0.6 % | 35.3 | 91 | 0 % |
| PL1 45 W + fans max | 6499 | +10.1 % | 45.4 | 92 | 0 % |
| PL1 45 W + BD PROCHOT off | 6518 | +10.4 % | 45.2 | 97 | 0 % |

With `int64`: +7.4 %. With `all` (mixed): +8.4 %.

### Combined CPU+GPU load

The dGPU (AMD Baffin, 40 W) is a separate package but **shares heatpipes and
fans** with the CPU — GPU load alone drags the idle CPU package to 80–85 °C.
Loaded with `glmark2-drm` at forced-high DPM plus `stress-ng`:

| Config | bogo-ops/s | CPU | GPU | PROCHOT |
|---|---|---|---|---|
| GPU only | — | 11.8 W / 80–85 °C | 25 W / 87 °C | 0 % |
| CPU only, PL1 45 W | 5941–6457 | 40–45 W / 94–98 °C | idle | 0–7 % |
| **CPU+GPU, PL1 45 W** | **6102–6110** | 41 W / 99 °C | 24 W / 87 °C | **0 %** |
| CPU+GPU, no cap | 5558–5566 | 39 W / 95 °C | 24 W / 87 °C | **20–25 %** |

### Conclusions

1. **PL1 = 45 W is the sweet spot** on this model: +7–10 % sustained across
   load types, PROCHOT eliminated, cooler, and far more *predictable*
   (σ 13–29 vs 94–115 bogo-ops/s).
2. The baseline only draws ~47 W — the firmware's 100 W PL1 never was the
   active limit. The gain comes from **changing the throttling regime**
   (eliminating PROCHOT collapses), not from "limiting power".
3. Disabling BD PROCHOT alone (the approach linked from the t2linux wiki via
   `turnoff-BD-PROCHOT`) is the fastest (+14.3 %) but runs pinned at 100 °C,
   draws more, and removes the VRM's only protection.
4. **Combining the cap with BD PROCHOT off adds nothing** over the cap alone —
   at 45 W PROCHOT no longer fires, so the bit is redundant. Keeping the
   protection costs ~0.6 % (within noise).
5. Forcing fans to max adds ~8 °C of headroom and no performance. The `applesmc`
   fan interface works, by the way — the attributes live on the ACPI device
   node (`APP0001:00/fan*_{input,output,manual}`), not under `hwmon/`.
6. Under combined CPU+GPU load the cap matters *more*: without it PROCHOT
   returns (20–25 %) and delivered CPU work drops ~9 % below the capped case.

**Caveats**: one machine, one model (`MacBookPro15,1`). Replications on other
T2 models welcome — the sweep is one command:
`sudo python3 bench/bench-throttling.py`. The 45 W value is specific to this
chassis/chip, which is why the installer gates the cap on the DMI model.

## Repo layout

```
build-t2-iso.sh            the ISO builder
autoinstall/late.sh        post-install, runs from late-commands
powercap/                  PL1 cap: defaults, script, systemd unit
t2-postinstall.sh          standalone post-install (plan B / existing installs)
bench/                     measurement scripts + raw CSV data
```

## Credits

- [t2linux](https://github.com/t2linux) — the kernel patches, ISOs, wiki and
  drivers that make any of this possible.
- [AdityaGarg8/t2-ubuntu-repo](https://github.com/AdityaGarg8/t2-ubuntu-repo)
  — the apt repo shipping `tiny-dfr`, `apple-firmware-script` and the T2 audio
  config.
- The firmware extraction script is by Aditya Garg, Orlando Chamberlain and
  Sharpened Blade, based on work by the Asahi Linux contributors.

Apple firmware is proprietary: it is extracted from *your* Mac's macOS at
install time and is never distributed by this repo or its ISOs.

## License

[MIT](LICENSE)
