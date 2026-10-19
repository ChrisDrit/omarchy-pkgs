#!/bin/bash
# bin/unpublish-plan retires an entry only from a channel and architecture no
# recipe publishes it to, and refuses a package a recipe still publishes
# everywhere it was asked for.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

recipe() { # recipe <name> <arches> [package.json]
  mkdir -p "$T/pkgbuilds/$1/.omarchy"
  printf 'pkgname=%s\npkgver=1\npkgrel=1\narch=(%s)\n' "$1" "$2" > "$T/pkgbuilds/$1/PKGBUILD"
  echo "${3:-"{\"source\": \"local\"}"}" > "$T/pkgbuilds/$1/.omarchy/package.json"
}
recipe edge-only "x86_64 aarch64" '{"source": "local", "channels": ["edge"]}'
recipe everywhere "x86_64 aarch64"
recipe arm-only "aarch64"
recipe icon-theme "any"
sed -i 's/^pkgname=icon-theme$/pkgbase=icons\npkgname=(icons-light icons-dark)/' "$T/pkgbuilds/icon-theme/PKGBUILD"

# The channel databases the plan reads names from, served over file://.
entry() { # entry <channel>/<arch> <name> <pkgbase>
  mkdir -p "$T/db/$1/$2-1-1"
  printf '%%NAME%%\n%s\n\n%%BASE%%\n%s\n\n%%VERSION%%\n1-1\n' "$2" "$3" > "$T/db/$1/$2-1-1/desc"
}
publish() {
  local c a
  for c in edge rc stable; do
    for a in x86_64 aarch64; do
      mkdir -p "$T/db/$c/$a" "$T/remote/$c/$a"
      tar --zstd -cf "$T/remote/$c/$a/omarchy.db" -C "$T/db/$c/$a" .
    done
  done
}
publish

plan() { OMARCHY_PKGBUILDS="$T/pkgbuilds" OMARCHY_PUBLISHED_REPO_URL="file://$T/remote" "$ROOT/bin/unpublish-plan" "$@" 2>"$T/err"; }
line() { grep "^$1=" <<<"$out" | cut -d= -f2-; }

out=$(plan --channels "edge rc stable" edge-only) || fail "edge-only refused: $(cat "$T/err")"
[[ $(line RETIRE_STABLE_X86_64) == edge-only && $(line RETIRE_RC_AARCH64) == edge-only ]] &&
  pass "an edge-only package is retired from rc and stable" || fail "edge-only plan: $out"
[[ -z $(line RETIRE_EDGE_X86_64) && -z $(line RETIRE_EDGE_AARCH64) ]] &&
  pass "and kept on edge, where its recipe publishes it" || fail "edge-only retired from edge: $out"

out=$(plan --channels "stable" arm-only gone) || fail "arm-only refused: $(cat "$T/err")"
[[ $(line RETIRE_STABLE_X86_64) == "arm-only gone" && $(line RETIRE_STABLE_AARCH64) == gone ]] &&
  pass "a dropped architecture and a removed recipe are retired, the rest kept" || fail "arch plan: $out"
[[ -z $(line RETIRE_RC_X86_64) ]] && pass "a channel not asked for is left alone" || fail "rc touched: $out"

plan --channels "edge rc stable" everywhere >/dev/null && fail "a package published everywhere was not refused"
grep -q "still published to every channel" "$T/err" && pass "a package still published everywhere asked for is refused" || fail "message: $(cat "$T/err")"
plan --channels "edge rc stable" icons >/dev/null && fail "a pkgbase built under another directory name was retired: $(cat "$T/err")"
pass "a pkgbase is matched to the recipe that builds it, whatever its directory is called"
plan --channels "edge" edge-only >/dev/null && fail "edge-only on edge was not refused"
pass "an edge-only package asked only for edge is refused"
plan --channels "stable beta" gone >/dev/null && fail "an unknown channel was accepted"
pass "an unknown channel is refused"
plan --channels "stable" 'bad name' >/dev/null && fail "a bad package name was accepted"
pass "a bad package name is refused"
out=$(plan --channels "stable" Gone-Up) || fail "a pkgbase makepkg allows was refused: $(cat "$T/err")"
[[ $(line RETIRE_STABLE_X86_64) == Gone-Up ]] && pass "any pkgbase makepkg allows can be planned, capitals too" || fail "Gone-Up plan: $out"
for bad in -dash .dot; do
  plan --channels "stable" "$bad" >/dev/null && fail "$bad was accepted"
done
pass "a name makepkg refuses is refused"
plan --channels >/dev/null && fail "a bare --channels was accepted"
pass "a bare --channels is refused"

# Only what recipes build counts. A package renamed in its own directory
# leaves its old pkgbase to be retired...
recipe renamed "x86_64 aarch64"
sed -i 's/^pkgname=renamed$/pkgname=new-name/' "$T/pkgbuilds/renamed/PKGBUILD"
out=$(plan --channels "stable" renamed) || fail "an old pkgbase was kept by its directory's name: $(cat "$T/err")"
[[ $(line RETIRE_STABLE_X86_64) == renamed && $(line RETIRE_STABLE_AARCH64) == renamed ]] &&
  pass "a pkgbase its directory no longer builds is retired" || fail "renamed plan: $out"
plan --channels "stable" new-name >/dev/null && fail "the new pkgbase was not kept"
pass "and the pkgbase it builds now is kept"
rm -r "$T/pkgbuilds/renamed"

# ...while packages still built under another pkgbase stay until a publish
# or a promotion replaces them by name.
recipe keep "x86_64 aarch64"
sed -i '1i pkgbase=keep-meta' "$T/pkgbuilds/keep/PKGBUILD"
plan --channels "edge rc stable" keep >/dev/null && fail "a pkgbase whose package is still built under another pkgbase was retired"
pass "a pkgbase whose package a recipe still builds under another pkgbase is kept"
rm -r "$T/pkgbuilds/keep"

recipe suite-v2 "x86_64 aarch64"
sed -i 's/^pkgname=suite-v2$/pkgname=(suite-a suite-b)/' "$T/pkgbuilds/suite-v2/PKGBUILD"
for slot in stable/x86_64 stable/aarch64; do entry "$slot" suite-a suite; entry "$slot" suite-b suite; done
publish
plan --channels "stable" suite >/dev/null && fail "split packages still built under another pkgbase were retired: $(cat "$T/err")"
pass "split packages the channel holds and a recipe still builds are kept, by the names the channel holds"
rm -r "$T/pkgbuilds/suite-v2" "$T/db/stable/x86_64/"suite-* "$T/db/stable/aarch64/"suite-*
publish

recipe kern "x86_64"
sed -i 's/^pkgname=kern$/pkgname=(kern kern-headers)/' "$T/pkgbuilds/kern/PKGBUILD"
recipe kern-arm "aarch64"
sed -i 's/^pkgname=kern-arm$/pkgbase=kern-arm\npkgname=(kern kern-headers)/' "$T/pkgbuilds/kern-arm/PKGBUILD"
entry edge/aarch64 kern kern
entry edge/aarch64 kern-headers kern
publish
plan --channels "edge" kern >/dev/null && fail "packages another recipe builds for aarch64 were retired: $(cat "$T/err")"
grep -q "Keeping kern in edge/aarch64: pkgbuilds/kern-arm" "$T/err" &&
  pass "a recipe that no longer builds an architecture does not hide one that builds its packages there" || fail "message: $(cat "$T/err")"
rm -r "$T/pkgbuilds/kern" "$T/pkgbuilds/kern-arm" "$T/db/edge/aarch64/"kern*
publish

recipe everywhere-arm "aarch64"
sed -i 's/^pkgname=everywhere-arm$/pkgname=everywhere/' "$T/pkgbuilds/everywhere-arm/PKGBUILD"
recipe everywhere "x86_64"
plan --channels "stable" everywhere >/dev/null && fail "a pkgbase two recipes build on different architectures was retired: $(cat "$T/err")"
grep -q "Keeping everywhere in stable/aarch64: pkgbuilds/everywhere-arm" "$T/err" &&
  pass "two recipes may share a pkgbase on different architectures" || fail "message: $(cat "$T/err")"
rm -r "$T/pkgbuilds/everywhere-arm"
recipe everywhere "x86_64 aarch64"

recipe everywhere-too "x86_64 aarch64"
sed -i 's/^pkgname=everywhere-too$/pkgname=everywhere/' "$T/pkgbuilds/everywhere-too/PKGBUILD"
plan --channels "stable" gone >/dev/null && fail "a plan was made although two recipes build one pkgbase"
grep -q "both build pkgbase everywhere" "$T/err" && pass "two recipes building one pkgbase stop the plan" || fail "message: $(cat "$T/err")"
rm -r "$T/pkgbuilds/everywhere-too"

mv "$T/remote/rc/aarch64/omarchy.db" "$T/rc-aarch64.db"
plan --channels "rc" gone >/dev/null && fail "a plan was made without the rc aarch64 database"
grep -q "Could not read file://$T/remote/rc/aarch64/omarchy.db" "$T/err" &&
  pass "a database that can't be read stops the plan" || fail "message: $(cat "$T/err")"
mv "$T/rc-aarch64.db" "$T/remote/rc/aarch64/omarchy.db"

# Every recipe has to be read in full before anything is planned: one left
# out of the lookup reads as gone, and its live packages would be retired.
rm "$T/pkgbuilds/icon-theme/.omarchy/package.json"
plan --channels "stable" icons >/dev/null && fail "a recipe without .omarchy/package.json read as gone: $(cat "$T/err")"
grep -q "pkgbuilds/icon-theme has no .omarchy/package.json" "$T/err" && pass "a recipe without metadata stops the plan" || fail "message: $(cat "$T/err")"
echo '{"source": "local"}' > "$T/pkgbuilds/icon-theme/.omarchy/package.json"

mv "$T/pkgbuilds/everywhere/PKGBUILD" "$T/PKGBUILD.everywhere"
plan --channels "stable" everywhere >/dev/null && fail "a recipe without a PKGBUILD read as gone: $(cat "$T/err")"
grep -q "pkgbuilds/everywhere has no PKGBUILD" "$T/err" && pass "a recipe directory without a PKGBUILD stops the plan" || fail "message: $(cat "$T/err")"
mv "$T/PKGBUILD.everywhere" "$T/pkgbuilds/everywhere/PKGBUILD"

for metadata in '{"source": "local", "channels": "edge"}' '{"source": "local", "channels": [' '{"channels": "edge"} {}'; do
  echo "$metadata" > "$T/pkgbuilds/everywhere/.omarchy/package.json"
  plan --channels "stable" everywhere >/dev/null && fail "channels that can't be read decided a retirement: $metadata"
  grep -q "Cannot read the channels of pkgbuilds/everywhere" "$T/err" || fail "message for $metadata: $(cat "$T/err")"
done
pass "channels that can't be read stop the plan"
echo '{"source": "local"}' > "$T/pkgbuilds/everywhere/.omarchy/package.json"

for root in "$T/nowhere" "$T/empty"; do
  mkdir -p "$T/empty"
  OMARCHY_PKGBUILDS="$root" "$ROOT/bin/unpublish-plan" --channels "stable" everywhere >/dev/null 2>"$T/err" &&
    fail "a plan was made from $root"
  grep -q "No recipes in $root" "$T/err" || fail "message for $root: $(cat "$T/err")"
done
pass "a missing or empty recipe directory stops the plan"

recipe quits "x86_64 aarch64"
sed -i '1i exit 0' "$T/pkgbuilds/quits/PKGBUILD"
plan --channels "stable" gone >/dev/null && fail "a plan was made although a PKGBUILD stopped before saying what it builds"
grep -q "Cannot read pkgbuilds/quits/PKGBUILD" "$T/err" && pass "a PKGBUILD that exits early with success stops the plan" || fail "message: $(cat "$T/err")"
rm -r "$T/pkgbuilds/quits"

recipe broken "x86_64 aarch64"
sed -i '1i return 1' "$T/pkgbuilds/broken/PKGBUILD"
plan --channels "stable" gone >/dev/null && fail "a plan was made although a PKGBUILD could not be read"
grep -q "Cannot read pkgbuilds/broken/PKGBUILD" "$T/err" && pass "a PKGBUILD that can't be read stops the plan" || fail "message: $(cat "$T/err")"
