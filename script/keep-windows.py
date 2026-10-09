#!/usr/bin/env python3
"""Keep every window where it is across an AeroSpace restart (`make install`).

A restart re-detects each window on the visible workspace of the monitor it sits on, so the
windows of every hidden workspace (parked in a screen corner) pile onto a visible one, and
workspace layouts go back to the default. aero-helper then runs `reset` (after-startup-command)
and clears the label of each Claude session workspace (CC<N>) it sees empty.

    keep-windows.py save              before the restart: each window's workspace and tree order,
                                      each workspace's root layout and monitor, floating windows,
                                      the visible workspaces, focus, and aero-helper's workspace labels
    keep-windows.py restore [--force] after: waits for AeroSpace to know every saved window, then
                                      puts back whatever moved. A no-op when nothing did.
    keep-windows.py restore --dry-run prints what restore would change, changes nothing

Nested containers come back flat: only each workspace's root layout is restored. Window ids
survive a restart, so window labels and ties (aero-helper) need nothing.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

SNAPSHOT = os.path.join(tempfile.gettempdir(), "aerospace-keep-windows.json")
LAST = os.path.join(tempfile.gettempdir(), "aerospace-keep-windows.last.json")
# Holds a workspace's windows while they go back in order
STAGING = "keep-windows-staging"
# An older snapshot isn't from this install (restore --force uses it anyway)
MAX_AGE = 15 * 60
DRY_RUN = "--dry-run" in sys.argv[2:]


def run(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired) as e:
        return subprocess.CompletedProcess(cmd, 1, "", str(e))


def change(*args):
    """An aerospace command that changes something. A failure is reported, not fatal."""
    if DRY_RUN:
        print(f"  would run: aerospace {' '.join(args)}")
        return False
    r = run("aerospace", *args)
    if r.returncode != 0:
        print(f"  ! aerospace {' '.join(args)}: {(r.stderr or r.stdout).strip()}")
    return r.returncode == 0


class Tree:
    """What `aerospace list-tree` says, indexed"""

    def __init__(self, raw):
        self.focused_window = raw["focused-window-id"]
        self.focused_workspace = None
        self.where = {}     # window id -> workspace
        self.order = {}     # workspace -> window ids, in tree order
        self.roots = {}     # workspace -> root container layout
        self.monitor = {}   # workspace -> monitor id
        self.visible = {}   # monitor id -> workspace
        self.floating = set()
        for monitor in raw["monitors"]:
            monitor_id = str(monitor["monitor-id"])  # str: it's a JSON key in the snapshot
            for ws in monitor["workspaces"]:
                name = ws["workspace"]
                self.roots[name] = ws["workspace-root-container-layout"]
                self.monitor[name] = monitor_id
                self.order[name] = [w["window-id"] for w in ws["windows"]]
                for w in ws["windows"]:
                    self.where[w["window-id"]] = name
                    if w["window-layout"] == "floating":
                        self.floating.add(w["window-id"])
                if ws["workspace-is-visible"]:
                    self.visible[monitor_id] = name
                if ws["workspace-is-focused"]:
                    self.focused_workspace = name


def read_tree():
    """None while AeroSpace isn't answering"""
    r = run("aerospace", "list-tree")
    if r.returncode != 0:
        return None
    try:
        return Tree(json.loads(r.stdout))
    except (ValueError, KeyError):
        return None


def tree_now():
    """list-tree mid-restore: AeroSpace has answered already, so silence now is an error"""
    tree = read_tree()
    if tree is None:
        raise SystemExit(f"keep-windows: AeroSpace stopped answering; `{sys.argv[0]} restore` to try again")
    return tree


def read_labels():
    """aero-helper's workspace labels: {} without aero-helper"""
    if not shutil.which("aero-helper"):
        return {}
    r = run("aero-helper", "label")
    if r.returncode != 0:
        print(f"  ! aero-helper label: {r.stderr.strip()}")
        return {}
    labels = {}
    for line in r.stdout.splitlines():
        workspace, _, text = line.partition("\t")
        if workspace and not workspace.startswith("#") and text:  # "#<id>" lines are window labels
            labels[workspace] = text
    return labels


def save():
    tree = read_tree()
    if tree is None:
        if os.path.exists(SNAPSHOT):
            os.remove(SNAPSHOT)
        print("keep-windows: AeroSpace isn't answering, nothing to keep")
        return 0
    snapshot = {
        "saved_at": time.time(),
        "focused_window": tree.focused_window,
        "focused_workspace": tree.focused_workspace,
        "visible": tree.visible,
        "workspaces": [{"name": name, "root": tree.roots[name], "monitor": tree.monitor[name],
                        "windows": [[wid, wid in tree.floating] for wid in ids]}
                       for name, ids in tree.order.items() if ids],
        "labels": read_labels(),
    }
    with open(SNAPSHOT + ".tmp", "w") as f:
        json.dump(snapshot, f, indent=2)
    os.replace(SNAPSHOT + ".tmp", SNAPSHOT)
    windows = sum(len(ws["windows"]) for ws in snapshot["workspaces"])
    print(f"keep-windows: saved {windows} windows on {len(snapshot['workspaces'])} workspaces, "
          f"{len(snapshot['labels'])} labels ({SNAPSHOT})")
    return 0


def wait_for_windows(ids, timeout=60):
    """The new AeroSpace once it answers and knows every saved window, or what it knows at the timeout"""
    deadline = time.time() + timeout
    tree = None
    while time.time() < deadline:
        tree = read_tree()
        if tree and ids <= set(tree.where):
            return tree
        time.sleep(0.5)
    return tree


def wait_for_reset(settle):
    """after-startup-command may run `aero-helper reset`, which moves windows home: let it finish"""
    time.sleep(settle)
    deadline = time.time() + 20
    while time.time() < deadline and run("pgrep", "-f", "aero-helper reset").returncode == 0:
        time.sleep(0.5)


def put_back(snapshot, gone):
    """One pass over the saved workspaces; returns whether it changed anything"""
    changed = False
    tree = tree_now()
    for ws in snapshot["workspaces"]:
        # A move appends to the workspace's root container, so saved order rebuilds the tree order
        for wid, _ in ws["windows"]:
            if wid not in gone and tree.where.get(wid) != ws["name"]:
                changed |= change("move-node-to-workspace", "--window-id", str(wid), ws["name"])
    tree = tree_now()
    for ws in snapshot["workspaces"]:
        tiled = [wid for wid, floating in ws["windows"] if not floating and wid not in gone]
        if [wid for wid in tree.order.get(ws["name"], []) if wid in tiled] != tiled:
            # Some were already there, out of order: take them all out and back in order
            for wid in tiled:
                change("move-node-to-workspace", "--window-id", str(wid), STAGING)
            for wid in tiled:
                change("move-node-to-workspace", "--window-id", str(wid), ws["name"])
            changed = True
    tree = tree_now()
    for ws in snapshot["workspaces"]:
        name = ws["name"]
        if any(not floating and wid not in gone for wid, floating in ws["windows"]) \
                and tree.roots.get(name) != ws["root"]:
            changed |= change("layout", "--workspace", name, "--root", ws["root"])
        for wid, floating in ws["windows"]:
            if floating and wid not in gone and wid not in tree.floating:
                changed |= change("layout", "--window-id", str(wid), "floating")
        # A workspace not pinned by workspace-to-monitor-force-assignment comes back on the main monitor
        if name in tree.monitor and tree.monitor[name] != ws["monitor"]:
            changed |= change("move-workspace-to-monitor", "--workspace", name, ws["monitor"])
    return changed


def put_labels_back(snapshot, gone):
    """aero-helper clears an empty CC<N>'s label, so once the helper has seen them filled again"""
    saved = snapshot["labels"]
    if not saved or not shutil.which("aero-helper"):
        return {}
    # A workspace whose windows are all gone stays empty: the helper would clear its label again
    emptied = {ws["name"] for ws in snapshot["workspaces"] if all(wid in gone for wid, _ in ws["windows"])}
    wanted = {ws: text for ws, text in saved.items() if ws not in emptied}

    def off():
        current = read_labels()
        return {ws: text for ws, text in wanted.items() if current.get(ws) != text}

    missing = off()
    if DRY_RUN:
        for ws, text in missing.items():
            print(f"  would run: aero-helper label -s {ws} {text!r}")
        return {}
    for _ in range(3):
        if not missing:
            break
        time.sleep(2)  # the helper refreshes about every second: until it sees the windows back, it clears them again
        for ws, text in missing.items():
            if run("aero-helper", "label", "-s", ws, text).returncode != 0:
                print(f"  ! aero-helper label -s {ws} {text!r}")
        time.sleep(1)
        missing = off()
    return missing


def put_focus_back(snapshot):
    tree = tree_now()
    for monitor, name in snapshot["visible"].items():
        if name != snapshot["focused_workspace"] and tree.visible.get(monitor) != name:
            if tree.monitor.get(name) != monitor:  # also when it doesn't exist yet: it'd open on the main monitor
                change("move-workspace-to-monitor", "--workspace", name, monitor)
            change("workspace", name)
    tree = tree_now()
    window = snapshot["focused_window"]
    if window is not None and window in tree.where:
        if tree.focused_window != window:
            change("focus", "--window-id", str(window))
    elif snapshot["focused_workspace"] and tree.focused_workspace != snapshot["focused_workspace"]:
        change("workspace", snapshot["focused_workspace"])


def restore(force):
    if not os.path.exists(SNAPSHOT):
        print("keep-windows: nothing saved, nothing to restore")
        return 0
    with open(SNAPSHOT) as f:
        snapshot = json.load(f)
    age = time.time() - snapshot["saved_at"]
    if age > MAX_AGE and not force:
        print(f"keep-windows: the snapshot is {age / 60:.0f} min old, not from this install: "
              f"`{sys.argv[0]} restore --force` to use it anyway")
        return 1
    saved = {wid: ws["name"] for ws in snapshot["workspaces"] for wid, _ in ws["windows"]}

    tree = wait_for_windows(set(saved))
    if tree is None:
        print(f"keep-windows: AeroSpace isn't answering; `{sys.argv[0]} restore` once it is")
        return 1
    gone = set(saved) - set(tree.where)
    # A late `aero-helper reset` (or on-window-detected rule) can still move a window: check again
    for attempt in range(3):
        wait_for_reset(settle=3 if attempt == 0 and not DRY_RUN else 0)
        if not put_back(snapshot, gone):
            break
        time.sleep(1.5)
    labels_off = put_labels_back(snapshot, gone)
    put_focus_back(snapshot)
    if DRY_RUN:
        print("keep-windows: dry run, nothing changed")
        return 0

    time.sleep(1)
    tree = tree_now()
    off = {wid: ws for wid, ws in saved.items() if wid not in gone and tree.where.get(wid) != ws}
    layouts_off = [ws["name"] for ws in snapshot["workspaces"]
                   if any(not floating and wid not in gone for wid, floating in ws["windows"])
                   and tree.roots.get(ws["name"]) != ws["root"]]
    print(f"keep-windows: {len(saved) - len(gone) - len(off)}/{len(saved)} windows back, "
          f"focus on {tree.focused_window}")
    if gone:
        print(f"  never came back (closed?): {sorted(gone)}")
    if off:
        print("  ! still elsewhere: " + ", ".join(f"{wid} (saved on {ws}, now {tree.where.get(wid)})"
                                                  for wid, ws in off.items()))
    if layouts_off:
        print(f"  ! root layout not restored on {', '.join(layouts_off)}")
    if labels_off:
        print(f"  ! labels not restored: {labels_off}")
    if off or layouts_off or labels_off:
        print(f"  the snapshot stays at {SNAPSHOT}: `{sys.argv[0]} restore` to try again")
        return 2
    os.replace(SNAPSHOT, LAST)
    return 0


def main():
    args = sys.argv[1:]
    if args[:1] == ["save"] and len(args) == 1:
        return save()
    if args[:1] == ["restore"] and set(args[1:]) <= {"--force", "--dry-run"}:
        return restore(force="--force" in args)
    print(__doc__)
    return 64


if __name__ == "__main__":
    sys.exit(main())
