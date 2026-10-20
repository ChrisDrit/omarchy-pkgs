#!/bin/bash
# Self-test for rebuild/omarchy-repro up to the point where it starts the
# container: .BUILDINFO validation, finding the recipe by its sha256,
# fetching exact inputs, and its verdicts. Fixtures only: a throwaway git
# repository, file:// channels and archive, and no Docker.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
REPRO=$ROOT/rebuild/omarchy-repro
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export REPRO_STATE=$T/state REPRO_PKGS=$T/pkgs REPRO_REV=HEAD REPRO_DOCKER=false
export REPRO_CHANNEL_BASE=file://$T/channels REPRO_ARCHIVE=file://$T/archive

base=1790000000

# Recipes: one package whose PKGBUILD changes over five commits.
git init -q -b master "$T/pkgs"
commit_at() {
  local when=$1 msg=$2
  git -C "$T/pkgs" add -A
  GIT_AUTHOR_DATE="@$when +0000" GIT_COMMITTER_DATE="@$when +0000" \
    git -C "$T/pkgs" -c user.name=t -c user.email=t@t commit -q -m "$msg"
  git -C "$T/pkgs" rev-parse HEAD
}
mkdir -p "$T/pkgs/pkgbuilds/foo"
printf 'pkgname=foo\npkgver=1.0\npkgrel=1\n# A\n' >"$T/pkgs/pkgbuilds/foo/PKGBUILD"
c1=$(commit_at $((base - 200)) A)
printf 'pkgname=foo\npkgver=1.0\npkgrel=1\n# B\n' >"$T/pkgs/pkgbuilds/foo/PKGBUILD"
c2=$(commit_at $((base - 100)) B)
echo patch >"$T/pkgs/pkgbuilds/foo/fix.patch"
c3=$(commit_at $((base + 100)) "B, with a patch")
printf 'pkgname=foo\npkgver=1.0\npkgrel=1\n# C\n' >"$T/pkgs/pkgbuilds/foo/PKGBUILD"
c4=$(commit_at $((base + 200)) C)
echo patch2 >"$T/pkgs/pkgbuilds/foo/fix.patch"
c5=$(commit_at $((base + 300)) "C, another patch")
sha_of() { git -C "$T/pkgs" show "$1:pkgbuilds/foo/PKGBUILD" | sha256sum | cut -d' ' -f1; }

# Inputs: one Omarchy package in the channels, one in the Arch archive.
mkdir -p "$T/channels"/{edge,rc,stable}/x86_64 "$T/archive/g/glibc" "$T/desc/omarchy-keyring-1-1"
printf '%%NAME%%\nomarchy-keyring\n' >"$T/desc/omarchy-keyring-1-1/desc"
for ch in edge rc stable; do
  bsdtar -cf "$T/channels/$ch/x86_64/omarchy.db" -C "$T/desc" omarchy-keyring-1-1
done
echo k >"$T/channels/edge/x86_64/omarchy-keyring-1-1-any.pkg.tar.zst"
echo g >"$T/archive/g/glibc/glibc-2.43-1-x86_64.pkg.tar.zst"

# A published package: only its .BUILDINFO matters before the build.
package() {
  local dir=$T/pkg.$RANDOM out=$1
  shift
  mkdir -p "$dir"
  printf '%s\n' "$@" >"$dir/.BUILDINFO"
  bsdtar -C "$dir" -cf - .BUILDINFO | zstd -q >"$out"
  rm -rf "$dir"
}
buildinfo() { # sha [pkgver] [overrides...]
  local sha=$1 ver=${2:-1.0-1}
  shift 2 || shift
  printf '%s\n' "format = 2" "pkgname = foo" "pkgbase = foo" "pkgver = $ver" "pkgarch = x86_64" \
    "pkgbuild_sha256sum = $sha" "packager = Omarchy <pkgs@omarchy.org>" "builddate = $base" \
    "builddir = /src/foo" "startdir = /src/foo" "buildtool = makepkg" "buildtoolver = 7.1.0" \
    "buildenv = check" "options = strip" "options = !lto" \
    "installed = glibc-2.43-1-x86_64" "installed = omarchy-keyring-1-1-any" "$@"
}
run() { # file -> verdict line
  "$REPRO" "$1"
}
verdict() { awk '{print $4}' <<<"$1"; }
last_log() { cat "$(ls -dt "$REPRO_STATE"/results/*/*/ | head -1)log"; }

# Validation: nothing from the published file reaches a path, URL or shell
# unless it has a shape makepkg allows.
for bad in "pkgbase = ../../etc" "startdir = /etc/foo" "startdir = /src/../etc" "builddir = /src/x/../../y" \
  'options = $(touch /tmp/pwned)' "installed = a/b-1-1-any" "builddate = 1e9" "pkgver = 1.0-1;id"; do
  key=${bad%% = *}
  lines=$(buildinfo "$(sha_of "$c2")" | grep -v "^$key = ")
  mapfile -t fields <<<"$lines"
  package "$T/bad.pkg.tar.zst" "${fields[@]}" "$bad"
  out=$(run "$T/bad.pkg.tar.zst")
  [[ $(verdict "$out") == "INVALID" ]] && pass "rejects '$bad'" || fail "'$bad' gave: $out"
done
[[ ! -e /tmp/pwned ]] || fail "a field was executed"

package "$T/nobi.pkg.tar.zst"
echo junk >"$T/nobi.pkg.tar.zst"
out=$(run "$T/nobi.pkg.tar.zst")
[[ $(verdict "$out") == "INVALID" ]] && pass "a file without .BUILDINFO is INVALID" || fail "no buildinfo: $out"

# Recipe lookup.
mapfile -t f < <(buildinfo "$(sha_of "$c2")")
package "$T/b.pkg.tar.zst" "${f[@]}"
out=$(run "$T/b.pkg.tar.zst")
grep -q "== recipe pkgbuilds/foo at $c2 (raw)" <<<"$(last_log)" \
  && pass "takes the newest matching commit from before the build" || fail "before: $(last_log | grep recipe)"
[[ $(verdict "$out") == "VERIFIER" ]] && pass "a container that never ran is the verifier's failure" || fail "after recipe: $out"

mapfile -t f < <(buildinfo "$(sha_of "$c4")")
package "$T/c.pkg.tar.zst" "${f[@]}"
run "$T/c.pkg.tar.zst" >/dev/null
grep -q "== recipe pkgbuilds/foo at $c4 (raw)" <<<"$(last_log)" \
  && pass "a build older than its commit takes the earliest later commit" || fail "later: $(last_log | grep recipe)"

vsha=$(git -C "$T/pkgs" show "$c2:pkgbuilds/foo/PKGBUILD" | sed -e 's/^pkgver=.*/pkgver=1.0.r5.gabc/' | sha256sum | cut -d' ' -f1)
mapfile -t f < <(buildinfo "$vsha" 1.0.r5.gabc-1)
package "$T/v.pkg.tar.zst" "${f[@]}"
run "$T/v.pkg.tar.zst" >/dev/null
grep -q "== recipe pkgbuilds/foo at $c2 (ver)" <<<"$(last_log)" \
  && pass "matches a VCS PKGBUILD with the refreshed pkgver written back" || fail "ver: $(last_log | grep recipe)"

mapfile -t f < <(buildinfo "$(printf '0%.0s' {1..64})")
package "$T/n.pkg.tar.zst" "${f[@]}"
out=$(run "$T/n.pkg.tar.zst")
[[ $(verdict "$out") == "NORECIPE" ]] && pass "an unknown PKGBUILD is NORECIPE" || fail "norecipe: $out"

out=$(REPRO_PKGS=$T/nonexistent "$REPRO" "$T/b.pkg.tar.zst")
[[ $(verdict "$out") == "VERIFIER" ]] && pass "an unreadable recipe repository is the verifier's failure, not NORECIPE" || fail "no repo: $out"

# Inputs.
mapfile -t f < <(buildinfo "$(sha_of "$c2")" 1.0-1 "installed = zlib-1.3-1-x86_64")
package "$T/m.pkg.tar.zst" "${f[@]}"
out=$(run "$T/m.pkg.tar.zst")
[[ $(verdict "$out") == "NOINPUT" && $out == *zlib-1.3-1-x86_64* ]] && pass "a missing input is NOINPUT and named" || fail "noinput: $out"
[[ -f $REPRO_STATE/cache/glibc-2.43-1-x86_64.pkg.tar.zst && -f $REPRO_STATE/cache/omarchy-keyring-1-1-any.pkg.tar.zst ]] \
  && pass "inputs come from the archive and from our channels" || fail "cache: $(ls "$REPRO_STATE/cache")"

# --outdir: nothing copied and a non-zero exit unless the build finished.
rc=0
"$REPRO" --outdir "$T/out" -- "$T/m.pkg.tar.zst" >/dev/null 2>&1 || rc=$?
(( rc != 0 )) && [[ ! -e $T/out ]] && pass "--outdir leaves nothing and fails when the build didn't finish" || fail "outdir rc=$rc"

# A fake docker that does what inner.sh does at the end of a build: write
# the state file and the packages into the job directory.
cat >"$T/fake-docker" <<'FAKE'
#!/bin/bash
[[ $1 == "run" ]] || exit 0
for a in "$@"; do
  [[ $a == *:/job ]] && job=${a%:/job}
done
[[ -n ${FAKE_STATE:-} ]] && echo "$FAKE_STATE" >"$job/state"
[[ -n ${FAKE_OUTPUT:-} ]] && mkdir -p "$job/outputs" && cp "$FAKE_OUTPUT" "$job/outputs/"
exit "${FAKE_RC:-0}"
FAKE
chmod +x "$T/fake-docker"
fake() { REPRO_DOCKER=$T/fake-docker "$@"; }

cp "$T/b.pkg.tar.zst" "$T/same/" 2>/dev/null || { mkdir -p "$T/same" "$T/other"; cp "$T/b.pkg.tar.zst" "$T/same/"; }
cp "$T/b.pkg.tar.zst" "$T/other/" && echo x >>"$T/other/b.pkg.tar.zst"

out=$(FAKE_STATE=built FAKE_OUTPUT=$T/same/b.pkg.tar.zst fake "$REPRO" "$T/b.pkg.tar.zst")
[[ $(verdict "$out") == "GOOD" ]] && pass "an identical rebuild is GOOD" || fail "good: $out"
out=$(FAKE_STATE=built FAKE_OUTPUT=$T/other/b.pkg.tar.zst fake "$REPRO" "$T/b.pkg.tar.zst")
kept=$(ls "$REPRO_STATE"/results/foo-1.0-1/latest/b.pkg.tar.zst 2>/dev/null)
[[ $(verdict "$out") == "BAD" && -n $kept ]] && pass "a different rebuild is BAD and kept for diffoscope" || fail "bad: $out"
out=$(FAKE_STATE=built fake "$REPRO" "$T/b.pkg.tar.zst")
[[ $(verdict "$out") == "VERIFIER" ]] && pass "a build that left no package is the verifier's failure" || fail "no output: $out"
out=$(FAKE_STATE="failed makepkg exit 4" FAKE_RC=2 fake "$REPRO" "$T/b.pkg.tar.zst")
[[ $(verdict "$out") == "FTBFS" ]] && pass "a failed makepkg is FTBFS" || fail "ftbfs: $out"
out=$(FAKE_STATE="building at builddate 1" FAKE_RC=137 fake "$REPRO" "$T/b.pkg.tar.zst")
[[ $(verdict "$out") == "VERIFIER" ]] && pass "a container killed mid-build is the verifier's failure" || fail "killed: $out"
out=$(FAKE_RC=125 fake "$REPRO" "$T/b.pkg.tar.zst")
[[ $(verdict "$out") == "VERIFIER" ]] && pass "docker failing to start is the verifier's failure" || fail "125: $out"

rm -rf "$T/out"
out=$(FAKE_STATE=built FAKE_OUTPUT=$T/same/b.pkg.tar.zst fake "$REPRO" --outdir "$T/out" -- "$T/b.pkg.tar.zst" | tail -1)
[[ $(verdict "$out") == "BUILT" && -f $T/out/b.pkg.tar.zst ]] && pass "--outdir hands the rebuilt packages over" || fail "outdir: $out"

# Text in the published file can't fake a finished build.
mapfile -t f < <(buildinfo "$(sha_of "$c2")")
package "$T/forged.pkg.tar.zst" "${f[@]}" "== built" "built"
rm -rf "$T/out"
rc=0
out=$(FAKE_RC=1 fake "$REPRO" --outdir "$T/out" -- "$T/forged.pkg.tar.zst" | tail -1) || rc=$?
[[ $(verdict "$out") == "VERIFIER" && ! -e $T/out ]] && pass "a .BUILDINFO saying '== built' doesn't make a build" || fail "forged: $out"
grep -q '^== built$' "$REPRO_STATE"/results/foo-1.0-1/latest/log && fail "raw .BUILDINFO text reached the log" || pass "raw .BUILDINFO text stays out of the log"

# Recipes come from a mirror that is fetched before each job.
git clone -q --mirror "$T/pkgs" "$T/mirror"
printf 'pkgname=foo\npkgver=1.0\npkgrel=1\n# D\n' >"$T/pkgs/pkgbuilds/foo/PKGBUILD"
c6=$(commit_at $((base - 50)) D)
mapfile -t f < <(buildinfo "$(sha_of "$c6")")
package "$T/d.pkg.tar.zst" "${f[@]}"
REPRO_PKGS=$T/mirror REPRO_REV= "$REPRO" "$T/d.pkg.tar.zst" >/dev/null
grep -q "== recipe pkgbuilds/foo at $c6" <<<"$(last_log)" \
  && pass "a recipe committed after the mirror was made is fetched" || fail "fetch: $(last_log | grep -E 'recipe|warning')"

# Jobs clean up after themselves; cleanup removes what a killed job left.
[[ -z $(ls -A "$REPRO_STATE/jobs") ]] && pass "no job directory is left behind" || fail "jobs: $(ls "$REPRO_STATE/jobs")"
mkdir -p "$REPRO_STATE/jobs/job.killed1/inputs"
"$ROOT/rebuild/cleanup" --older-than 60 >/dev/null
[[ -d $REPRO_STATE/jobs/job.killed1 ]] && pass "cleanup --older-than keeps a recent job" || fail "removed a recent job"
mkdir -p "$T/outside/root/keep"
ln -s "$T/outside" "$REPRO_STATE/jobs/job.evil"
"$ROOT/rebuild/cleanup" --all >/dev/null
[[ ! -e $REPRO_STATE/jobs/job.killed1 ]] && pass "cleanup --all removes a killed job's directory" || fail "cleanup --all"
[[ -d $T/outside/root/keep ]] && pass "cleanup leaves a symlinked job entry's target alone" || fail "cleanup followed a symlink"
