#!/usr/bin/env bash
# The running AeroSpace must be the installed build. On 2026-10-14 something relaunched AeroSpace while `make install`
# had it quit, before the copy: the old binary kept running, and the new code looked broken. The check compares inodes:
# rsync -a keeps the build's mtime, so the binary's mtime says nothing about when it was installed.
set -e # Exit if one of commands exit with non-zero exit code
set -u # Treat unset variables and parameters other than the special parameters ‘@’ or ‘*’ as an error
set -o pipefail # Any command failed in the pipe fails the whole pipe

binary=${AEROSPACE_BINARY:-/Applications/AeroSpace.app/Contents/MacOS/AeroSpace} # Overridable to test the failure
installed=$(stat -f %i "$binary")

for _ in $(seq 1 20); do
    pid=$(pgrep -x AeroSpace || true)
    if [ -n "$pid" ]; then
        # -F: one field per line. i<inode> comes before n<name> for each open file
        running=$(lsof -a -p "$pid" -d txt -Fin 2>/dev/null | awk '/^i/ { inode = substr($0, 2) } /^n.*\/MacOS\/AeroSpace$/ { print inode }')
        if [ "$running" = "$installed" ]; then
            echo "check-running-build: AeroSpace $pid runs the installed build"
            exit 0
        fi
        echo "check-running-build: AeroSpace $pid runs inode ${running:-?}, but the installed build is inode $installed." >&2
        echo "Quit AeroSpace, open /Applications/AeroSpace.app, then ./script/keep-windows.py restore" >&2
        exit 1
    fi
    sleep 0.5
done
echo "check-running-build: AeroSpace isn't running" >&2
exit 1
