#!/bin/bash
# bin/check-channel-drift fails on a channel database entry no recipe
# publishes there (recipe gone, architecture dropped, channels narrowed),
# names the unpublish that retires it, and leaves promotion lag alone. With
# --base it fails only on drift the change adds.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

recipe() { # recipe <dir> <name> <arches> [package.json]
  mkdir -p "$1/$2/.omarchy"
  printf 'pkgname=%s\npkgver=1\npkgrel=1\narch=(%s)\n' "$2" "$3" > "$1/$2/PKGBUILD"
  echo "${4:-"{\"source\": \"local\"}"}" > "$1/$2/.omarchy/package.json"
}
recipe "$T/pkgbuilds" everywhere "x86_64 aarch64"
recipe "$T/pkgbuilds" edge-only "x86_64 aarch64" '{"source": "local", "channels": ["edge"]}'
recipe "$T/pkgbuilds" arm-only "aarch64"
recipe "$T/pkgbuilds" lagging "x86_64 aarch64"
recipe "$T/pkgbuilds" icon-theme "any"
sed -i 's/^pkgname=icon-theme$/pkgbase=icons\npkgname=(icons-light icons-dark)/' "$T/pkgbuilds/icon-theme/PKGBUILD"
recipe "$T/pkgbuilds" carch "x86_64 aarch64"
sed -i 's/^pkgname=carch$/if [[ $CARCH == "aarch64" ]]; then pkgname=carch-arm; else pkgname=carch; fi/' "$T/pkgbuilds/carch/PKGBUILD"

entry() { # entry <channel>/<arch> <name> [pkgbase]
  mkdir -p "$T/db/$1/$2-1-1"
  printf '%%FILENAME%%\n%s-1-1-any.pkg.tar.zst\n\n%%NAME%%\n%s\n\n%%BASE%%\n%s\n\n%%VERSION%%\n1-1\n\n%%BUILDDATE%%\n1788000000\n' \
    "$2" "$2" "${3:-$2}" > "$T/db/$1/$2-1-1/desc"
}
publish() { # one database per channel and architecture from $T/db
  local c a
  for c in edge rc stable; do
    for a in x86_64 aarch64; do
      mkdir -p "$T/db/$c/$a" "$T/remote/$c/$a"
      tar --zstd -cf "$T/remote/$c/$a/omarchy.db" -C "$T/db/$c/$a" .
    done
  done
}
for slot in {edge,rc,stable}/{x86_64,aarch64}; do entry "$slot" everywhere; done
entry edge/x86_64 edge-only
entry edge/aarch64 arm-only
entry edge/x86_64 lagging
entry edge/x86_64 icons-light icons
entry edge/aarch64 icons-dark icons
entry edge/x86_64 carch
entry edge/aarch64 carch-arm
publish

check() { # check [--base <dir>]: run against the fixtures and the recipes in $HEAD, output in $out, status in $rc
  rc=0
  out=$(OMARCHY_PUBLISHED_REPO_URL="file://$T/remote" OMARCHY_PKGBUILDS="${HEAD:-$T/pkgbuilds}" \
    "$ROOT/bin/check-channel-drift" "$@" 2>&1) || rc=$?
}

check
(( rc == 0 )) && pass "channels that hold only what recipes publish pass" || fail "clean channels: $out"
[[ $out != *"::error::"* ]] && pass "a recipe edge holds but rc and stable lack yet is not drift" || fail "lag reported: $out"
[[ $out != *carch* ]] && pass "a recipe is read for each architecture as makepkg would read it" || fail "CARCH: $out"
[[ $out == *"Every channel database holds only packages a recipe publishes there."* ]] || fail "clean message: $out"

cp -r "$T/pkgbuilds" "$T/narrowed"
recipe "$T/narrowed" everywhere "x86_64 aarch64" '{"source": "local", "channels": ["edge", "rc"]}'
HEAD="$T/narrowed" check --base "$T/pkgbuilds"
(( rc == 1 )) && [[ $out == *"::error::stable/aarch64 holds everywhere"* && $out != *"Before this change"* ]] &&
  pass "a change that adds drift to clean channels fails" || fail "drift on a clean base passed: $out"

# The three ways an entry outlives its recipe.
entry stable/x86_64 edge-only
entry edge/x86_64 arm-only
entry rc/x86_64 gone
entry rc/x86_64 gone-debug gone
publish
cp -r "$T/pkgbuilds" "$T/base"
check
(( rc == 1 )) && pass "drift fails the check" || fail "drift passed ($rc): $out"
[[ $out == *"::error::stable/x86_64 holds edge-only 1-1 (built 2026-08-29): pkgbuilds/edge-only leaves stable out of its channels"* ]] &&
  pass "an entry in a channel its recipe leaves out is drift" || fail "narrowed channels: $out"
[[ $out == *"::error::edge/x86_64 holds arm-only 1-1 (built 2026-08-29): pkgbuilds/arm-only does not build for x86_64"* ]] &&
  pass "an entry for an architecture its recipe dropped is drift" || fail "dropped architecture: $out"
[[ $out == *"::error::rc/x86_64 holds "*"gone 1-1 (built 2026-08-29)"*": no recipe builds it"* && $out == *gone-debug* ]] &&
  pass "an entry whose recipe is gone is drift, with its split packages" || fail "removed recipe: $out"
(( $(grep -c '::error::' <<<"$out") == 3 )) && pass "nothing a recipe publishes is reported" || fail "extra errors: $out"
[[ $out == *'gh workflow run unpublish.yml -R omacom/omarchy-pkgs -f packages="arm-only edge-only gone" -f channels="edge rc stable"'* ]] &&
  pass "the unpublish that retires it is printed" || fail "dispatch: $out"
plan=$(OMARCHY_PKGBUILDS="$T/pkgbuilds" "$ROOT/bin/unpublish-plan" --channels "edge rc stable" arm-only edge-only gone 2>/dev/null)
[[ $plan == *$'RETIRE_EDGE_X86_64=arm-only gone\n'* && $plan == *$'RETIRE_RC_X86_64=arm-only edge-only gone\n'* && $plan == *$'RETIRE_STABLE_X86_64=arm-only edge-only gone\n'* ]] &&
  pass "and unpublish-plan accepts it" || fail "unpublish-plan: $plan"

check --base "$T/base"
(( rc == 0 )) && pass "a change that adds no drift passes, whatever was there before" || fail "old drift failed a change: $out"
[[ $out == *"Before this change, 3 database and pkgbase pairs"* && $out != *"::error::"* ]] && pass "old drift is counted, not reported as the change's" || fail "old drift: $out"

recipe "$T/pkgbuilds" everywhere "x86_64 aarch64" '{"source": "local", "channels": ["edge"]}'
check --base "$T/base"
(( rc == 1 )) && pass "narrowing a recipe's channels under a live entry fails" || fail "narrowed channels passed: $out"
[[ $out == *"::error::rc/aarch64 holds everywhere"* && $out == *"::error::stable/x86_64 holds everywhere"* && $out != *"::error::edge/"* ]] &&
  pass "in the channels it left, and only there" || fail "narrowed slots: $out"
[[ $out == *'-f packages="everywhere" -f channels="rc stable"'* && $out == *"Once it is merged"* ]] &&
  pass "with the unpublish that should follow the merge" || fail "narrowed dispatch: $out"

recipe "$T/pkgbuilds" everywhere "x86_64"
check --base "$T/base"
(( rc == 1 )) && [[ $out == *"::error::edge/aarch64 holds everywhere 1-1 (built 2026-08-29): pkgbuilds/everywhere does not build for aarch64"* && $out != *"::error::edge/x86_64"* ]] &&
  pass "dropping an architecture under a live entry fails" || fail "dropped architecture passed: $out"

rm -r "$T/pkgbuilds/everywhere"
check --base "$T/base"
(( rc == 1 && $(grep -c '::error::.* holds everywhere' <<<"$out") == 6 )) &&
  pass "deleting a recipe without its unpublish fails in every channel it held" || fail "deleted recipe: $out"

recipe "$T/pkgbuilds" broken "x86_64 aarch64"
echo "return 1" >> "$T/pkgbuilds/broken/PKGBUILD"
check
(( rc == 2 )) && [[ $out == *"Cannot read pkgbuilds/broken/PKGBUILD"* && $out != *"::error::"*" holds "* ]] &&
  pass "a PKGBUILD that cannot be read fails closed, not as drift" || fail "unreadable PKGBUILD ($rc): $out"
mkdir "$T/broken-base"
cp -r "$T/pkgbuilds/broken" "$T/broken-base/"
rm -r "$T/pkgbuilds/broken"
check --base "$T/broken-base"
(( rc == 2 )) && [[ $out == *"Cannot read the recipes in $T/broken-base, the ones before this change"* ]] &&
  pass "recipes before the change that cannot be read fail closed, and say so" || fail "unreadable base ($rc): $out"

# Every entry has to be a record repo-add writes; one that can't be read
# would otherwise drop out of the check.
malformed() { # malformed <entry> <desc, or "none">: one such entry in edge/x86_64
  mkdir -p "$T/db/edge/x86_64/$1"
  if [[ $2 == "none" ]]; then
    touch "$T/db/edge/x86_64/$1/files"
  else
    printf '%b' "$2" > "$T/db/edge/x86_64/$1/desc"
  fi
  publish
  check
  rm -r "$T/db/edge/x86_64/$1"
}
for record in 'nobase-1-1|%NAME%\nnobase\n\n%VERSION%\n1-1\n' 'noname-1-1|%BASE%\nnoname\n\n%VERSION%\n1-1\n' 'nover-1-1|%NAME%\nnover\n\n%BASE%\nnover\n'; do
  malformed "${record%%|*}" "${record#*|}"
  (( rc == 2 )) && [[ $out == *"::error::edge/x86_64 holds ${record%%|*} without a %NAME%, %BASE% or %VERSION%"* ]] ||
    fail "entry ${record%%|*} ($rc): $out"
done
pass "an entry without %NAME%, %BASE% or %VERSION% fails closed"
for entry in nodesc-1-1 emptydesc-1-1; do
  if [[ $entry == "nodesc-1-1" ]]; then malformed "$entry" none; else malformed "$entry" ""; fi
  (( rc == 2 )) && [[ $out == *"::error::edge/x86_64 holds $entry without a desc"* ]] || fail "entry $entry ($rc): $out"
done
pass "an entry without a desc, or with an empty one, fails closed"
publish

# Every recipe has to be read in full too; one left out would read as gone.
recipe "$T/pkgbuilds" no-metadata "x86_64"
rm "$T/pkgbuilds/no-metadata/.omarchy/package.json"
check
(( rc == 2 )) && [[ $out == *"pkgbuilds/no-metadata has no .omarchy/package.json"* && $out != *" holds "* ]] &&
  pass "a recipe without metadata fails closed, not as drift" || fail "recipe without metadata ($rc): $out"
rm -r "$T/pkgbuilds/no-metadata"
cp "$T/pkgbuilds/edge-only/.omarchy/package.json" "$T/edge-only.json"
for metadata in '{"source": "local", "channels": "edge"}' '{"channels": "edge"} {}'; do
  echo "$metadata" > "$T/pkgbuilds/edge-only/.omarchy/package.json"
  check
  (( rc == 2 )) && [[ $out == *"Cannot read the channels of pkgbuilds/edge-only"* && $out != *" holds "* ]] ||
    fail "unreadable channels $metadata ($rc): $out"
done
pass "channels that can't be read fail closed, not as drift"
cp "$T/edge-only.json" "$T/pkgbuilds/edge-only/.omarchy/package.json"
recipe "$T/pkgbuilds" quits "x86_64"
sed -i '1i exit 0' "$T/pkgbuilds/quits/PKGBUILD"
check
(( rc == 2 )) && [[ $out == *"Cannot read pkgbuilds/quits/PKGBUILD"* && $out != *" holds "* ]] &&
  pass "a PKGBUILD that exits early with success fails closed, not as drift" || fail "early exit ($rc): $out"
rm -r "$T/pkgbuilds/quits"

for args in "--help" "--base" "--base $T/nowhere" "--base $T/base extra"; do
  read -ra argv <<<"$args"
  check "${argv[@]}"
  (( rc == 2 )) && [[ $out == *"usage:"* ]] || fail "bad arguments '$args' were accepted ($rc): $out"
done
pass "bad arguments are refused"

rm "$T/remote/rc/aarch64/omarchy.db"
check
(( rc == 2 )) && [[ $out == *"Could not read file://$T/remote/rc/aarch64/omarchy.db"* ]] &&
  pass "a database that cannot be read fails closed" || fail "unreadable database ($rc): $out"
