#!/bin/sh
# Caps the sustained CPU power to avoid the sawtooth throttling of the
# 2018 15" MacBook Pro with the i9-8950HK.
#
# Without this: hits 100 C in 4 s, trips PROCHOT and collapses to 799 MHz.
# With this: stays flat around ~3000 MHz. Measured on stress-ng matrixprod:
# +7-10% sustained bogo-ops/s vs firmware defaults, and PROCHOT eliminated
# (including under combined CPU+GPU load).
set -e
[ -r /etc/default/t2-powercap ] && . /etc/default/t2-powercap
PL1_WATTS=${PL1_WATTS:-45}
PL1_WINDOW_US=${PL1_WINDOW_US:-1000000}

P=/sys/class/powercap/intel-rapl/intel-rapl:0
[ -d "$P" ] || { echo "intel-rapl not available, nothing to do"; exit 0; }

# Write order does not matter (tested both ways), but note that thermald
# tracks these values and may adjust the limit downwards under thermal
# pressure - that is desirable and does not undo this cap.
echo "$PL1_WINDOW_US" > "$P/constraint_0_time_window_us"
echo $((PL1_WATTS * 1000000)) > "$P/constraint_0_power_limit_uw"

echo "PL1 = $(($(cat "$P/constraint_0_power_limit_uw")/1000000)) W, window $(cat "$P/constraint_0_time_window_us") us"
