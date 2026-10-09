#!/usr/bin/env python3
"""Tests for keep-windows.py: `./script/keep-windows-test.py` (no AeroSpace needed, about a minute).

Runs its save / restore against fake `aerospace` and `aero-helper` CLIs that keep their state in a
JSON file. The fakes mimic the semantics keep-windows relies on: a move appends to the target's
root container, an empty hidden workspace is garbage-collected, a new workspace lives on its forced
monitor or the main one, `workspace X` shows X on its monitor, and move-workspace-to-monitor makes
the workspace the target monitor's active one, leaving a stub on its previous monitor.
"""
import copy
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "keep-windows.py")


# The fakes: Env installs them as bin/aerospace and bin/aero-helper

def load():
    with open(os.environ["FAKE_STATE"]) as f:
        return json.load(f)


def store(s):
    with open(os.environ["FAKE_STATE"], "w") as f:
        json.dump(s, f)


def log(*a):
    with open(os.environ["FAKE_LOG"], "a") as f:
        f.write(" ".join(a) + "\n")


def ensure(s, ws):
    if ws not in s["workspaces"]:
        s["workspaces"][ws] = {"monitor": s["forced"].get(ws, s["main"]), "root": "h_tiles", "windows": []}
    return s["workspaces"][ws]


def gc(s):
    visible = set(s["visible"].values())
    for name in [n for n, w in s["workspaces"].items() if not w["windows"] and n not in visible]:
        del s["workspaces"][name]


def where(s, wid):
    return next((n for n, w in s["workspaces"].items() if wid in w["windows"]), None)


def show(s, ws):
    w = ensure(s, ws)
    s["visible"][str(w["monitor"])] = ws
    s["focused_workspace"] = ws


def fake_aerospace(args):
    s = load()
    if args == ["list-tree"]:
        monitors = []
        for m in sorted(s["monitors"]):
            wss = [{"workspace": name, "workspace-root-container-layout": w["root"],
                    "workspace-is-visible": s["visible"].get(str(m)) == name,
                    "workspace-is-focused": s["focused_workspace"] == name,
                    "windows": [{"window-id": wid, "app-name": "app",
                                 "window-layout": "floating" if wid in s["floating"] else w["root"]}
                                for wid in w["windows"]]}
                   for name, w in s["workspaces"].items() if w["monitor"] == m]
            monitors.append({"monitor-id": m, "workspaces": wss})
        print(json.dumps({"focused-window-id": s["focused_window"], "monitors": monitors}))
        return 0
    log("aerospace", *args)
    if args[:2] == ["move-node-to-workspace", "--window-id"]:
        wid, ws = int(args[2]), args[3]
        src = where(s, wid)
        if src == ws:
            print("noop")
            return 0
        s["workspaces"][src]["windows"].remove(wid)
        ensure(s, ws)["windows"].append(wid)
    elif args[:2] == ["layout", "--workspace"] and args[3] == "--root":
        if args[2] not in s["workspaces"]:
            print("no such workspace", file=sys.stderr)
            return 1
        s["workspaces"][args[2]]["root"] = args[4]
    elif args[:2] == ["layout", "--window-id"] and args[3] == "floating":
        s["floating"].append(int(args[2]))
    elif args[:2] == ["move-workspace-to-monitor", "--workspace"]:
        ws, m = args[2], int(args[3])
        w = ensure(s, ws)
        prev = w["monitor"]
        if prev == m:
            return 0
        if s["forced"].get(ws, m) != m:
            print("forced elsewhere", file=sys.stderr)
            return 1
        w["monitor"] = m
        s["visible"][str(m)] = ws
        stub = next(f"stub{i}" for i in range(1, 99) if f"stub{i}" not in s["workspaces"])
        s["workspaces"][stub] = {"monitor": prev, "root": "h_tiles", "windows": []}
        s["visible"][str(prev)] = stub
        if s["focused_workspace"] not in s["visible"].values():
            s["focused_workspace"], s["focused_window"] = stub, None
    elif args[0] == "workspace":
        show(s, args[1])
        s["focused_window"] = (s["workspaces"][args[1]]["windows"] or [None])[-1]
    elif args[:2] == ["focus", "--window-id"]:
        wid = int(args[2])
        show(s, where(s, wid))
        s["focused_window"] = wid
    else:
        print(f"fake aerospace: unknown {args}", file=sys.stderr)
        return 2
    gc(s)
    store(s)
    return 0


def fake_helper(args):
    s = load()
    if args == ["label"]:
        for ws, text in sorted(s["labels"].items()):
            print(f"{ws}\t{text}")
        print("#28940\t\twith 28325")  # a window's tie: not a workspace label
        return 0
    if args[:2] == ["label", "-s"]:
        log("aero-helper", *args)
        s["labels"][args[2]] = args[3]
        store(s)
        return 0
    print(f"fake aero-helper: unknown {args}", file=sys.stderr)
    return 2


# The tests

BASE = {
    "monitors": [1, 2], "main": 2,
    "forced": {name: 2 for name in ["1-A", "CC1", "CC2", "CC3", "CC5"]},
    "workspaces": {
        "1": {"monitor": 1, "root": "h_tiles", "windows": []},
        "1-A": {"monitor": 2, "root": "h_accordion", "windows": [20100]},
        "CC1": {"monitor": 2, "root": "h_accordion", "windows": [27623, 28169]},
        "CC2": {"monitor": 2, "root": "v_tiles", "windows": [29014, 777]},
        "CC5": {"monitor": 2, "root": "h_accordion", "windows": [28325, 28940]},
        "Temp1": {"monitor": 1, "root": "v_accordion", "windows": [500, 501]},  # not pinned, on monitor 1
        "zzArc": {"monitor": 2, "root": "h_tiles", "windows": [29304]},
    },
    "floating": [777],
    "visible": {"1": "1", "2": "1-A"},
    "focused_workspace": "1-A", "focused_window": 20100,
    "labels": {"CC1": "Claude setup", "CC2": "Aero helper", "CC5": "Jarvis", "CC5-Aerospace": "Workspace labels"},
}


class Env:
    """A fake AeroSpace + aero-helper with `state`, and keep-windows.py run against them"""

    def __init__(self, root, state):
        self.dir = tempfile.mkdtemp(dir=root)
        os.makedirs(os.path.join(self.dir, "bin"))
        for tool, fn in [("aerospace", "fake_aerospace"), ("aero-helper", "fake_helper")]:
            path = os.path.join(self.dir, "bin", tool)
            with open(path, "w") as f:
                f.write(f"#!{sys.executable}\nimport importlib.util, sys\n"
                        f"spec = importlib.util.spec_from_file_location('fakes', {os.path.abspath(__file__)!r})\n"
                        "fakes = importlib.util.module_from_spec(spec)\nspec.loader.exec_module(fakes)\n"
                        f"sys.exit(fakes.{fn}(sys.argv[1:]))\n")
            os.chmod(path, 0o755)
        self.state_path = os.path.join(self.dir, "state.json")
        self.log_path = os.path.join(self.dir, "log.txt")
        open(self.log_path, "w").close()
        self.put(state)
        self.env = dict(os.environ, PATH=os.path.join(self.dir, "bin") + ":" + os.environ["PATH"],
                        FAKE_STATE=self.state_path, FAKE_LOG=self.log_path, TMPDIR=self.dir,
                        PYTHONDONTWRITEBYTECODE="1")  # the fakes import this file: no __pycache__ in script/

    def put(self, state):
        with open(self.state_path, "w") as f:
            json.dump(state, f)

    def get(self):
        with open(self.state_path) as f:
            return json.load(f)

    def run(self, *args):
        r = subprocess.run([sys.executable, SCRIPT, *args], env=self.env, capture_output=True, text=True, timeout=120)
        return r.returncode, r.stdout + r.stderr

    def log(self):
        with open(self.log_path) as f:
            return f.read().splitlines()


def restart(s, scramble=None):
    """What an AeroSpace restart does: the windows of hidden workspaces land on the main monitor's
    visible workspace (all of them, for simplicity), layouts go back to tiles, nothing floats,
    another workspace shows on monitor 1, and the helper clears the labels of emptied CC<N>"""
    s = copy.deepcopy(s)
    landing = s["visible"][str(s["main"])]
    moved = []
    for name, w in s["workspaces"].items():
        if name not in s["visible"].values():
            moved += w["windows"]
            w["windows"] = []
    s["workspaces"][landing]["windows"] += list(reversed(moved))
    for w in s["workspaces"].values():
        w["root"] = "h_tiles"
    s["floating"] = []
    gc(s)
    for name in list(s["labels"]):
        if re.fullmatch(r"CC\d+", name) and not s["workspaces"].get(name, {}).get("windows"):
            del s["labels"][name]
    s["visible"]["1"] = "2"
    s["workspaces"]["2"] = {"monitor": 1, "root": "h_tiles", "windows": []}
    gc(s)
    s["focused_window"] = None
    if scramble:
        scramble(s)
    return s


def differences(env, saved, gone=()):
    now = env.get()
    problems = []
    for name, w in saved["workspaces"].items():
        want = [wid for wid in w["windows"] if wid not in gone]
        if not want:
            continue
        have = now["workspaces"].get(name)
        if not have or have["windows"] != want:
            problems.append(f"{name}: windows {have and have['windows']} != {want}")
            continue
        if any(wid not in saved["floating"] for wid in want) and have["root"] != w["root"]:
            problems.append(f"{name}: root {have['root']} != {w['root']}")
        if have["monitor"] != w["monitor"]:
            problems.append(f"{name}: monitor {have['monitor']} != {w['monitor']}")
    if sorted(set(now["floating"])) != sorted(set(saved["floating"]) - set(gone)):
        problems.append(f"floating {now['floating']} != {saved['floating']}")
    if now["visible"] != saved["visible"]:
        problems.append(f"visible {now['visible']} != {saved['visible']}")
    if now["focused_window"] != saved["focused_window"]:
        problems.append(f"focused {now['focused_window']} != {saved['focused_window']}")
    return problems, now


def exit_ok(code, out):
    return [] if code == 0 else [f"exit {code}: {out}"]


def test_no_op(root):
    env = Env(root, BASE)
    env.run("save")
    code, out = env.run("restore")
    return exit_ok(code, out) + ([f"changed something: {env.log()}"] if env.log() else [])


def test_restart(root):
    env = Env(root, BASE)
    env.run("save")
    env.put(restart(BASE))
    code, out = env.run("restore")
    problems, now = differences(env, BASE)
    if now["labels"] != BASE["labels"]:
        problems.append(f"labels {now['labels']}")
    return problems + exit_ok(code, out)


def test_out_of_order(root):
    # CC1 is on screen, so its windows stay on it; something puts 28169 ahead of 27623
    s = copy.deepcopy(BASE)
    s["visible"]["2"], s["focused_workspace"], s["focused_window"] = "CC1", "CC1", 28169
    env = Env(root, s)
    env.run("save")

    def swap(r):
        cc1 = r["workspaces"]["CC1"]["windows"]
        cc1.remove(28169)
        cc1.insert(0, 28169)
    env.put(restart(s, swap))
    code, out = env.run("restore")
    return differences(env, s)[0] + exit_ok(code, out)


def test_window_gone(root):
    env = Env(root, BASE)
    env.run("save")

    def close_cc2(r):
        for w in r["workspaces"].values():
            w["windows"] = [wid for wid in w["windows"] if wid not in (29014, 777)]
    env.put(restart(BASE, close_cc2))
    code, out = env.run("restore")
    problems, now = differences(env, BASE, gone={29014, 777})
    if "CC2" in now["labels"]:
        problems.append("restored the label of CC2, which has no windows left")
    if "never came back" not in out:
        problems.append(f"didn't report the closed windows: {out}")
    if "  ! " in out:
        problems.append(f"reported a failure: {out}")
    return problems + exit_ok(code, out)


def test_nothing_saved(root):
    env = Env(root, BASE)
    code, out = env.run("restore")
    return exit_ok(code, out) + ([f"changed something: {env.log()}"] if env.log() else [])


def test_stale_snapshot(root):
    env = Env(root, BASE)
    env.run("save")
    path = os.path.join(env.dir, "aerospace-keep-windows.json")
    with open(path) as f:
        snapshot = json.load(f)
    snapshot["saved_at"] -= 3600
    with open(path, "w") as f:
        json.dump(snapshot, f)
    env.put(restart(BASE))
    code, out = env.run("restore")
    problems = [] if code == 1 and not env.log() else [f"exit {code}, changes {env.log()}: {out}"]
    code, out = env.run("restore", "--force")
    return problems + exit_ok(code, out)


def test_dry_run(root):
    env = Env(root, BASE)
    env.run("save")
    env.put(restart(BASE))
    code, out = env.run("restore", "--dry-run")
    problems = [] if code == 0 and not env.log() and "would run: aerospace move-node-to-workspace" in out \
        and "would run: aero-helper label -s CC1" in out else [f"exit {code}, changes {env.log()}: {out}"]
    code, out = env.run("restore")  # the snapshot is still there for the real one
    return problems + differences(env, BASE)[0] + exit_ok(code, out)


TESTS = [
    ("no-op: nothing moved, nothing changed", test_no_op),
    ("restart: everything back (order, layouts, floating, monitors, labels, visible, focus)", test_restart),
    ("a window already there out of order goes back in order", test_out_of_order),
    ("closed windows are reported, their emptied workspace's label left alone", test_window_gone),
    ("restore without a snapshot does nothing", test_nothing_saved),
    ("a stale snapshot needs --force", test_stale_snapshot),
    ("dry run: prints the moves and labels, changes nothing, keeps the snapshot", test_dry_run),
]


def main():
    root = tempfile.mkdtemp(prefix="keep-windows-test-")
    ok = True
    try:
        for name, test in TESTS:
            problems = test(root)
            ok &= not problems
            print(("PASS " if not problems else "FAIL ") + name)
            for p in problems:
                print("   ", p)
    finally:
        shutil.rmtree(root)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
