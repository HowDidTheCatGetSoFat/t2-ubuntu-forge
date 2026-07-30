#!/usr/bin/env python3
"""
Power-cap configuration sweep on a MacBookPro15,1 (i9-8950HK) under Linux.

Measures DELIVERED PERFORMANCE (stress-ng bogo-ops/s), not frequency, and REAL
POWER (RAPL energy_uj deltas), not inferred. For each run it also samples the
IA32_THERM_STATUS "performance limit reasons" MSR (0x64F) to attribute the
throttling to its actual cause (thermal, PROCHOT, PL1/PL2, VR current).

Run as root, detached. Incremental results in /var/log/t2-bench/results.csv.
Restores all state on exit, even if interrupted.

Environment overrides: BENCH_DUR (s per run), BENCH_REPS, BENCH_LIMIT
(first N configs only), BENCH_COOL_T, BENCH_COOL_MAX.
"""
import os, sys, time, csv, struct, subprocess, signal, atexit

OUTDIR   = "/var/log/t2-bench"
DEV      = "/sys/devices/LNXSYSTM:00/LNXSYBUS:00/PNP0A08:00/device:102/APP0001:00"
RAPL     = "/sys/class/powercap/intel-rapl/intel-rapl:0"
NCPU     = 12
DUR      = int(os.environ.get("BENCH_DUR", 60))    # seconds of load per run
REPS     = int(os.environ.get("BENCH_REPS", 3))
LIMIT    = int(os.environ.get("BENCH_LIMIT", 0))   # >0 = only first N configs
COOL_T   = int(os.environ.get("BENCH_COOL_T", 62)) # cool down to this temp between runs
COOL_MAX = int(os.environ.get("BENCH_COOL_MAX", 200))
TZ       = "/sys/class/thermal/thermal_zone2/temp"
MSR_REASONS = 0x64F
MSR_POWER_CTL = 0x1FC   # bit 0 = BD PROCHOT enable

REASONS = {0:"PROCHOT", 1:"thermal", 4:"residency", 5:"ratl", 6:"vr_therm",
           7:"vr_tdc_current", 8:"other", 10:"pl1", 11:"pl2", 12:"max_turbo",
           13:"turbo_trans"}

def sh(cmd, **kw):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, **kw)

def wr(path, val):
    with open(path, "w") as f: f.write(str(val))

def rdf(path, default=None):
    try:
        with open(path) as f: return f.read().strip()
    except Exception: return default

def rdmsr(msr, cpu=0):
    fd = os.open(f"/dev/cpu/{cpu}/msr", os.O_RDONLY)
    try: return struct.unpack("<Q", os.pread(fd, 8, msr))[0]
    finally: os.close(fd)

def temp():   return int(rdf(TZ, "0")) // 1000
def energy(): return int(rdf(f"{RAPL}/energy_uj", "0"))
ENERGY_MAX = int(rdf(f"{RAPL}/max_energy_range_uj", "0"))

def freqs():
    out = []
    for c in range(NCPU):
        v = rdf(f"/sys/devices/system/cpu/cpu{c}/cpufreq/scaling_cur_freq")
        if v: out.append(int(v) // 1000)
    return out

# ---------------- state control ----------------
def set_pl1(watts, window_us):
    wr(f"{RAPL}/constraint_0_time_window_us", int(window_us))
    wr(f"{RAPL}/constraint_0_power_limit_uw", int(watts * 1_000_000))
    got_w = int(rdf(f"{RAPL}/constraint_0_power_limit_uw", "0")) // 1_000_000
    got_t = int(rdf(f"{RAPL}/constraint_0_time_window_us", "0"))
    return got_w, got_t

def set_fans(mode):
    """mode: None = automatic, 'max' = forced to maximum"""
    for n in (1, 2):
        if mode == "max":
            wr(f"{DEV}/fan{n}_manual", 1)
            wr(f"{DEV}/fan{n}_output", rdf(f"{DEV}/fan{n}_max", "5000"))
        else:
            wr(f"{DEV}/fan{n}_manual", 0)

def set_bdprochot(enabled):
    """BD PROCHOT: bit 0 of MSR 0x1FC. Applied to all cores."""
    v = rdmsr(MSR_POWER_CTL)
    nv = (v | 1) if enabled else (v & ~1)
    sh(f"wrmsr -a {hex(MSR_POWER_CTL)} {hex(nv)}")
    return bool(rdmsr(MSR_POWER_CTL) & 1)

def rpms():
    return (int(rdf(f"{DEV}/fan1_input", "0")), int(rdf(f"{DEV}/fan2_input", "0")))

# ---------------- guaranteed cleanup ----------------
def cleanup():
    print("[cleanup] restoring state", flush=True)
    sh("pkill -9 -x stress-ng")
    try: set_fans(None)
    except Exception as e: print(f"[cleanup] fans: {e}")
    try: set_bdprochot(True)
    except Exception as e: print(f"[cleanup] bdprochot: {e}")
    sh("systemctl start thermald")
    sh("systemctl restart t2-powercap")
    print(f"[cleanup] done. PL1={int(rdf(f'{RAPL}/constraint_0_power_limit_uw','0'))//10**6}W "
          f"fans_manual={rdf(f'{DEV}/fan1_manual')} bdprochot={bool(rdmsr(MSR_POWER_CTL)&1)}", flush=True)

atexit.register(cleanup)
for s in (signal.SIGINT, signal.SIGTERM):
    signal.signal(s, lambda *a: sys.exit(1))

# ---------------- cooldown ----------------
def cooldown():
    t0 = time.time()
    while temp() > COOL_T and time.time() - t0 < COOL_MAX:
        time.sleep(5)
    return round(time.time() - t0), temp()

# ---------------- one run ----------------
def run(cfg_name, cfg, method, rep):
    pl1_w, pl1_t = set_pl1(cfg["pl1"], cfg["win"])
    set_fans(cfg["fans"])
    bdp = set_bdprochot(cfg["bdp"])
    cool_s, cool_temp = cooldown()

    yml = f"/tmp/sng-{cfg_name}-{method}-{rep}.yaml"
    e0, t0 = energy(), time.time()
    p = subprocess.Popen(
        f"stress-ng --cpu {NCPU} --cpu-method {method} -t {DUR}s "
        f"--metrics --yaml {yml}", shell=True,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    samples, tmax, reason_hits = [], 0, {k: 0 for k in REASONS.values()}
    n = 0
    while p.poll() is None:
        time.sleep(1)
        T = temp(); tmax = max(tmax, T)
        f = freqs()
        v = rdmsr(MSR_REASONS)
        for b, name in REASONS.items():
            if v >> b & 1: reason_hits[name] += 1
        samples.append((T, sum(f)//len(f) if f else 0))
        n += 1
        if n > DUR + 60: break   # safety net
    p.wait()
    dt = time.time() - t0
    de = energy() - e0
    if de < 0: de += ENERGY_MAX
    watts = round(de / 1e6 / dt, 1)

    bogo = None
    for line in (rdf(yml, "") or "").splitlines():
        if "bogo-ops-per-second-real-time" in line:
            bogo = float(line.split(":")[1]); break

    # drop the first 10 s (transient) for the sustained average
    st = samples[10:] if len(samples) > 15 else samples
    r1, r2 = rpms()
    return dict(
        config=cfg_name, load=method, rep=rep,
        pl1_set=cfg["pl1"], pl1_actual=pl1_w, window_us=pl1_t,
        fans=cfg["fans"] or "auto", bdprochot=bdp,
        bogo_ops_s=bogo,
        mhz_sustained=round(sum(s[1] for s in st)/len(st)) if st else 0,
        temp_avg=round(sum(s[0] for s in st)/len(st)) if st else 0,
        temp_max=tmax, watts_avg=watts,
        fan1_rpm=r1, fan2_rpm=r2,
        cooldown_s=cool_s, cooldown_temp=cool_temp,
        **{f"pct_{k}": round(100*v/max(n,1)) for k, v in reason_hits.items()
           if k in ("PROCHOT","thermal","pl1","pl2","vr_tdc_current","vr_therm")}
    )

# ---------------- plan ----------------
FW_WIN = 27983872   # firmware default PL1 window (~28 s)
CONFIGS = [
    ("baseline-100W",          dict(pl1=100, win=FW_WIN,  fans=None,  bdp=True)),
    ("pl1-55W",                dict(pl1=55,  win=1000000, fans=None,  bdp=True)),
    ("pl1-45W",                dict(pl1=45,  win=1000000, fans=None,  bdp=True)),
    ("pl1-40W",                dict(pl1=40,  win=1000000, fans=None,  bdp=True)),
    ("pl1-35W",                dict(pl1=35,  win=1000000, fans=None,  bdp=True)),
    ("pl1-45W+fansmax",        dict(pl1=45,  win=1000000, fans="max", bdp=True)),
    ("pl1-45W+nobdprochot",    dict(pl1=45,  win=1000000, fans=None,  bdp=False)),
    ("pl1-45W+fansmax+nobdp",  dict(pl1=45,  win=1000000, fans="max", bdp=False)),
    ("baseline+nobdprochot",   dict(pl1=100, win=FW_WIN,  fans=None,  bdp=False)),
]
# matrixprod = heavy FP/vector load. The other two only on baseline and 45W.
PLAN = [(c, "matrixprod") for c in CONFIGS]
PLAN += [(c, m) for c in CONFIGS if c[0] in ("baseline-100W", "pl1-45W")
                for m in ("int64", "all")]

def main():
    global PLAN
    if LIMIT: PLAN = PLAN[:LIMIT]
    os.makedirs(OUTDIR, exist_ok=True)
    sh("modprobe msr")
    # thermald reverts PL1 changes: stopped for the whole sweep, restored at the end
    sh("systemctl stop thermald")
    print(f"[plan] {len(PLAN)} configurations x {REPS} reps = {len(PLAN)*REPS} runs", flush=True)
    print(f"[plan] ~{round(len(PLAN)*REPS*(DUR+60)/60)} min estimated", flush=True)

    csvp = f"{OUTDIR}/results.csv"
    w = None
    with open(csvp, "w", newline="") as fh:
        for i, ((name, cfg), method) in enumerate(PLAN, 1):
            for rep in range(1, REPS+1):
                print(f"[{i}/{len(PLAN)} rep{rep}] {name} / {method} ...", flush=True)
                try:
                    row = run(name, cfg, method, rep)
                except Exception as e:
                    print(f"  ERROR: {e}", flush=True); continue
                if w is None:
                    w = csv.DictWriter(fh, fieldnames=list(row.keys())); w.writeheader()
                w.writerow(row); fh.flush()
                print(f"  bogo/s={row['bogo_ops_s']} {row['mhz_sustained']}MHz "
                      f"{row['watts_avg']}W {row['temp_avg']}C(max {row['temp_max']}) "
                      f"PROCHOT={row['pct_PROCHOT']}% thermal={row['pct_thermal']}% "
                      f"pl1={row['pct_pl1']}%", flush=True)
    print("[done] sweep complete", flush=True)

if __name__ == "__main__":
    main()
