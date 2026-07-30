#!/usr/bin/env python3
"""
Combined CPU+GPU load on a MacBookPro15,1: measures whether the dGPU (AMD
Baffin, 40W cap, shared heatpipes) brings back the PROCHOT throttling that
the PL1=45W cap had eliminated.

Run as root with gdm and thermald stopped (both restored on exit).
"""
import os, sys, time, csv, struct, subprocess, signal, atexit, glob

OUT   = "/var/log/t2-bench/gpu.csv"
RAPL  = "/sys/class/powercap/intel-rapl/intel-rapl:0"
TZ    = "/sys/class/thermal/thermal_zone2/temp"
DEV   = "/sys/devices/LNXSYSTM:00/LNXSYBUS:00/PNP0A08:00/device:102/APP0001:00"
DUR   = int(os.environ.get("BENCH_DUR", 60))
REPS  = int(os.environ.get("BENCH_REPS", 2))
COOL_T, COOL_MAX = 62, 240
NCPU  = 12
REASONS = {0:"PROCHOT",1:"thermal",7:"vr_tdc",10:"pl1",11:"pl2"}

AMD = None
for h in glob.glob("/sys/class/hwmon/hwmon*"):
    try:
        if open(f"{h}/name").read().strip() == "amdgpu": AMD = h; break
    except Exception: pass

# dGPU DPM: on this install it sits at "low" (clock pinned to 214MHz even at
# 100% busy). To actually load it, "high" must be forced.
# The observed original state is "low": THAT is what gets restored at the end.
DPM = "/sys/devices/pci0000:00/0000:00:01.0/0000:01:00.0/power_dpm_force_performance_level"
DPM_ORIG = "low"

def sh(c): return subprocess.run(c, shell=True, capture_output=True, text=True)
def rdf(p, d=None):
    try: return open(p).read().strip()
    except Exception: return d
def wr(p, v): open(p,"w").write(str(v))
def rdmsr(m):
    fd = os.open("/dev/cpu/0/msr", os.O_RDONLY)
    try: return struct.unpack("<Q", os.pread(fd,8,m))[0]
    finally: os.close(fd)
def temp(): return int(rdf(TZ,"0"))//1000
def gpu_w(): return round(int(rdf(f"{AMD}/power1_input","0"))/1e6,1)
def gpu_t(): return int(rdf(f"{AMD}/temp1_input","0"))//1000
def cpu_energy(): return int(rdf(f"{RAPL}/energy_uj","0"))
EMAX = int(rdf(f"{RAPL}/max_energy_range_uj","1"))
def freqs():
    fs=[int(rdf(f"/sys/devices/system/cpu/cpu{c}/cpufreq/scaling_cur_freq","0"))//1000 for c in range(NCPU)]
    return sum(fs)//len(fs)

def set_pl1(w, win):
    wr(f"{RAPL}/constraint_0_time_window_us", win)
    wr(f"{RAPL}/constraint_0_power_limit_uw", w*1_000_000)

def cleanup():
    print("[cleanup]", flush=True)
    sh("pkill -9 -x glmark2-drm; pkill -9 -x stress-ng")
    try: wr(DPM, DPM_ORIG)
    except Exception as e: print(f"[cleanup] dpm: {e}")
    sh("systemctl start gdm3 2>/dev/null || systemctl start gdm")
    sh("systemctl start thermald")
    sh("systemctl restart t2-powercap")
    print("[cleanup] done", flush=True)
atexit.register(cleanup)
for s in (signal.SIGINT, signal.SIGTERM): signal.signal(s, lambda *a: sys.exit(1))

def cooldown():
    t0=time.time()
    while temp()>COOL_T and time.time()-t0<COOL_MAX: time.sleep(5)

def run(name, pl1, win, cpu_load, gpu_load, rep):
    set_pl1(pl1, win); cooldown()
    yml=f"/tmp/g-{name}-{rep}.yaml"; procs=[]
    if gpu_load:
        wr(DPM, "high")
        procs.append(subprocess.Popen("glmark2-drm --run-forever -b jellyfish -b refract",
                     shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        time.sleep(5)  # let the GPU settle into its regime
        if gpu_w() < 15:
            print(f"  WARNING: GPU drawing {gpu_w()}W after 5s — weak load or wrong chip?", flush=True)
    else:
        wr(DPM, DPM_ORIG)
    sng=None
    if cpu_load:
        sng=subprocess.Popen(f"stress-ng --cpu {NCPU} --cpu-method matrixprod -t {DUR}s --metrics --yaml {yml}",
              shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        procs.append(sng)
    e0,t0=cpu_energy(),time.time()
    hits={n:0 for n in REASONS.values()}; n=0; ct=[]; gw=[]; gt=[]; mhz=[]
    while time.time()-t0 < DUR:
        time.sleep(1)
        v=rdmsr(0x64F)
        for b,nm in REASONS.items():
            if v>>b&1: hits[nm]+=1
        ct.append(temp()); gw.append(gpu_w()); gt.append(gpu_t()); mhz.append(freqs()); n+=1
    dt=time.time()-t0; de=cpu_energy()-e0
    if de<0: de+=EMAX
    for p in procs:
        if p is not sng: p.kill()
    if sng: sng.wait()
    sh("pkill -9 -x glmark2-drm")
    bogo=None
    for line in (rdf(yml,"") or "").splitlines():
        if "bogo-ops-per-second-real-time" in line: bogo=float(line.split(":")[1]); break
    st=slice(8,None)
    row=dict(config=name, rep=rep, pl1=pl1, cpu_load=int(cpu_load), gpu_load=int(gpu_load),
        bogo_ops_s=bogo, cpu_w=round(de/1e6/dt,1), gpu_w=round(sum(gw[st])/max(len(gw[st]),1),1),
        cpu_temp=round(sum(ct[st])/max(len(ct[st]),1)), gpu_temp=round(sum(gt[st])/max(len(gt[st]),1)),
        mhz=round(sum(mhz[st])/max(len(mhz[st]),1)),
        fan1=rdf(f"{DEV}/fan1_input"), fan2=rdf(f"{DEV}/fan2_input"),
        **{f"pct_{k}":round(100*v/max(n,1)) for k,v in hits.items()})
    return row

FW=27983872
PLAN=[
    ("gpu-only",            100, FW,      False, True),
    ("cpu45",               45,  1000000, True,  False),
    ("cpu45+gpu",           45,  1000000, True,  True),
    ("cpu100+gpu",          100, FW,      True,  True),
]

def main():
    if not AMD: print("amdgpu hwmon not found"); sys.exit(1)
    sh("modprobe msr")
    sh("systemctl stop thermald")
    sh("systemctl stop gdm3 2>/dev/null || systemctl stop gdm")
    time.sleep(3)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    w=None
    with open(OUT,"w",newline="") as fh:
        for name,pl1,win,cl,gl in PLAN:
            for rep in range(1,REPS+1):
                print(f"[{name} rep{rep}]", flush=True)
                row=run(name,pl1,win,cl,gl,rep)
                if w is None:
                    w=csv.DictWriter(fh,fieldnames=list(row.keys())); w.writeheader()
                w.writerow(row); fh.flush()
                print(f"  bogo/s={row['bogo_ops_s']} cpu={row['cpu_w']}W/{row['cpu_temp']}C "
                      f"gpu={row['gpu_w']}W/{row['gpu_temp']}C {row['mhz']}MHz "
                      f"PROCHOT={row['pct_PROCHOT']}% thermal={row['pct_thermal']}% pl1={row['pct_pl1']}%", flush=True)
    print("[done]", flush=True)

if __name__=="__main__": main()
