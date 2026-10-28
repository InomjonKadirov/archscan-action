#!/usr/bin/env bash
#
# run-archscan.sh IMAGE [archscan args…]
#
# Runs the ArchScan image like a local `archscan` command: the action runs every scan and diff through
# it, and ArchScan's own end-to-end smoke test uses it as a launcher.
#
# The container runs with the caller's uid/gid, so the files it writes stay the caller's. The current
# directory and TMPDIR are bind-mounted at the same absolute paths, so absolute paths in configs and
# arguments mean the same inside the container. --quiet keeps docker's pull progress out of the
# output. Exit codes pass through (archscan's 0/1/2, docker's own 125+).
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: $0 IMAGE [archscan args…]" >&2; exit 2; }
image="$1"; shift

here="$PWD"
tmp="$(cd "${TMPDIR:-/tmp}" && pwd)"   # normalised: no trailing or doubled slashes
mounts=(--mount "type=bind,source=$here,target=$here")
[ "$tmp" = "$here" ] || mounts+=(--mount "type=bind,source=$tmp,target=$tmp")

exec docker run --rm --quiet --user "$(id -u):$(id -g)" "${mounts[@]}" -w "$here" "$image" "$@"
