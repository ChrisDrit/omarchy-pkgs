#!/bin/bash
#
# rebuilderd backend: rebuilderd-worker runs this with one published package
# of a build as $1 and REBUILDERD_OUTDIR set, then compares every package of
# that build with the file of the same name in REBUILDERD_OUTDIR.
#
# /etc/rebuilderd-worker.conf:
#   [backend."archlinux"]
#   path = "/usr/libexec/rebuilderd/rebuilder-omarchy.sh"   (a symlink to this file)

set -eu
here=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
exec "$here/omarchy-repro" --nocheck --outdir "$REBUILDERD_OUTDIR" -- "$1"
