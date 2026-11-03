#!/usr/bin/env python3
"""quickshot_exec: load autosave -> exec console commands -> verified in-game -> shots.

Usage: quickshot_exec.py <tag> [ENV=VAL ...] [--exec "cmd1;cmd2" ...]
Screenshots: Anomaly/appdata/screenshots/<tag>_ing.jpg, <tag>_ing2.jpg
Log:         engine/harness/logs/metal_<tag>.log

Same evidence gate as quickshot2, plus console cvars applied right after the
level load so a probe can toggle engine features (water SSR, sun shafts, ...).
"""
import os, sys, time, subprocess

tag = sys.argv[1]
root = "/Users/jdella/Desktop/anomaly-metal-native"
cwd = os.path.join(root, "Anomaly")
logdir = os.path.join(root, "engine", "harness", "logs")
os.makedirs(logdir, exist_ok=True)
log = os.path.join(logdir, "metal_%s.log" % tag)
binpath = os.path.join(root, "engine", "build-gl", "bin", "xr_3da")

execs = []
envs = []
args = sys.argv[2:]
i = 0
while i < len(args):
    if args[i] == "--exec":
        i += 1
        execs.append(args[i])
    else:
        envs.append(args[i])
    i += 1


def nc(cmds, w=10):
    script = "; ".join("printf '%s\\n'; sleep 3" % c for c in cmds)
    p = subprocess.run(["bash", "-c", "(%s) | nc -w %d 127.0.0.1 27846" % (script, w + 6)],
                       capture_output=True, text=True, cwd=cwd)
    return (p.stdout or "").strip().splitlines()


def mcp(cmd, w=10):
    return nc([cmd], w)


env = dict(os.environ)
env.update({"XR_RENDERER": "metal", "SDL_AUDIODRIVER": "dummy", "ALSOFT_DRIVERS": "null",
            "SDL_VIDEO_WINDOW_POS": "100,100"})
for kv in envs:
    k, _, v = kv.partition("=")
    env[k] = v

subprocess.run(["pkill", "-9", "-x", "xr_3da"])
time.sleep(4)
logfd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
p = subprocess.Popen([binpath, "-nointro", "-renderer", "metal", "-mcp"],
                     cwd=cwd, stdout=logfd, stderr=logfd, env=env)

for i in range(60):
    out = mcp("ping", 4)
    if out and out[0].startswith("pong"):
        break
    time.sleep(2)

mcp("exec snd_volume_eff 0")
mcp("exec snd_volume_music 0")
print("ga:", mcp("exec g_always_active 1"), flush=True)
time.sleep(2)
print("l1:", mcp("exec start server(player - autosave/single/alife/load) client(localhost)"), flush=True)
time.sleep(10)
print("l2:", mcp("exec snd_volume_eff 0"), flush=True)
for e in execs:
    print("exec:", e, "->", mcp("exec " + e), flush=True)


def parse(s):
    d = {}
    for tok in s.split():
        if "=" in tok:
            k, _, v = tok.partition("=")
            d[k] = v
    return d


verified = False
for i in range(90):
    out = mcp("state", 6)
    line = out[-1] if out else ""
    d = parse(line)
    print("poll:", out, flush=True)
    if d.get("in_game") == "1" and d.get("level") == "k00_marsh" and d.get("precache") == "0":
        try:
            fps = float(d.get("fps", "0"))
            frame = int(d.get("frame", "0"))
        except ValueError:
            fps, frame = 0.0, 0
        if fps <= 0.5:
            print("tap:", mcp("key RETURN"), flush=True)
        elif fps > 5 and frame > 4500:
            verified = True
            break
    time.sleep(4)

if not verified:
    print("NOT VERIFIED", flush=True)
else:
    for i in range(60):
        out = mcp("state", 6)
        line = out[-1] if out else ""
        d = parse(line)
        try:
            frame = int(d.get("frame", "0"))
        except ValueError:
            frame = 0
        if frame >= 6800:
            print("wait:", line, flush=True)
            break
        time.sleep(3)
    print("shot:", mcp("screenshot %s_ing" % tag), flush=True)
    time.sleep(2)
    print("shot2:", mcp("screenshot %s_ing2" % tag), flush=True)
    time.sleep(2)

mcp("quit")
time.sleep(3)
subprocess.run(["pkill", "-9", "-x", "xr_3da"])
print("DONE", flush=True)
