#!/usr/bin/env bash
# settle_profile.sh <profile> <copy> [wait]: the instrumented server rewrites its whole profile
# every ~12 s (a 54 MB write of ~3 s, then ~9 s still, whatever --instrumentation-sleep-time
# says), and the dump at exit is cut short when the container stops. After <wait> seconds
# (65) this copies the file in a still window: same size four seconds apart and at least
# 50 MB, the size of a complete dump of this binary.
set -u
sleep "${3:-65}"
until s1=$(stat -c %s "$1") && sleep 4 && s2=$(stat -c %s "$1") && [ "$s1" = "$s2" ] && [ "$s1" -gt 50000000 ]; do :; done
cp "$1" "$2" && ls -la "$2"
