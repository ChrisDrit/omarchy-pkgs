#!/bin/bash
# bin/unpublish-packages removes exactly the entries built from the named
# pkgbases, whatever order a record's fields come in, says so when it cannot
# list the remote, and handles a database it empties or finds empty.
# Needs rclone, repo-remove and bsdtar (run in the Arch test container).
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

record() { # record <name> <field>...: a db entry with its fields in the order given
  local field
  mkdir -p "$T/db/$1-1-1"
  : > "$T/db/$1-1-1/desc"
  for field in "${@:2}"; do
    case $field in
      NAME | BASE) printf '%%%s%%\n%s\n\n' "$field" "$1" ;;
      VERSION) printf '%%VERSION%%\n1-1\n\n' ;;
    esac >> "$T/db/$1-1-1/desc"
  done
}
publish() { # the edge x86_64 database from $T/db, laid out as repo-add writes it
  rm -rf "$T/r2"
  mkdir -p "$T/r2/edge/x86_64"
  (cd "$T/db" && tar --zstd -cf "$T/r2/edge/x86_64/omarchy.db.tar.zst" -- *)
}
unpublish() { "$ROOT/bin/unpublish-packages" --remote "$T/r2" --mirror edge --arch x86_64 "$@" >"$T/out" 2>&1; }
entries() { tar -tf "$T/r2/edge/x86_64/omarchy.db.tar.zst" | grep '/$' | sort | tr '\n' ' ' || true; }

record active NAME BASE VERSION
record retired BASE NAME VERSION
publish
unpublish retired || fail "unpublish failed: $(cat "$T/out")"
[[ $(entries) == "active-1-1/ " ]] && pass "only the named pkgbase goes, whatever the order of its fields" || fail "entries left: $(entries)"

unpublish active || fail "emptying the database failed: $(cat "$T/out")"
[[ -z $(entries) ]] && pass "a database can be emptied" || fail "entries left: $(entries)"
unpublish active || fail "a re-run on an empty database failed: $(cat "$T/out")"
grep -q "None of active is in edge/x86_64" "$T/out" && pass "a re-run on an empty database changes nothing" || fail "message: $(cat "$T/out")"

unpublish() { "$ROOT/bin/unpublish-packages" --remote "nosuchremote:bucket" --mirror edge --arch x86_64 "$@" >"$T/out" 2>&1; }
unpublish active && fail "a remote that could not be listed read as having no database: $(cat "$T/out")"
pass "a remote that cannot be listed fails"
