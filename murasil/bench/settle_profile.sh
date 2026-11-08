#!/usr/bin/env bash
# settle_profile.sh <profile> <copy> [wait]: the instrumented server rewrites its profile every
# minute; after <wait> seconds (65) this waits until the file has been still for ten seconds and
# copies it, since the dump at exit is cut short when the container is stopped.
set -u
sleep "${3:-65}"
until [ -s "$1" ] && [ $(( $(date +%s) - $(stat -c %Y "$1") )) -ge 10 ]; do sleep 2; done
cp "$1" "$2" && ls -la "$2"
