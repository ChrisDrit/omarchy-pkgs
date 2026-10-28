#!/bin/bash
# Self-test for bin/publish-artifact, and its counterpart bin/unpublish-packages,
# against a local directory as the remote.
# Needs repo-add, gpg, rclone, bsdtar (run in the Arch builder/test container).
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d); chmod 755 "$T"; trap 'rm -rf "$T"' EXIT
REMOTE="$T/r2"; mkdir -p "$REMOTE"

# throwaway signing key
export GNUPGHOME="$T/g"; mkdir -m700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'Test <t@t>' ed25519 sign 0 2>/dev/null
export GPG_PRIVATE_KEY=$(gpg --batch --armor --export-secret-keys 'Test <t@t>') GPG_PASSPHRASE=''
unset GNUPGHOME

# minimal real packages via makepkg
mkpkg() { # mkpkg <name> <pkgrel> <arch> [payload]
  local d="$T/src/$1-$2${4:+-$4}"; mkdir -p "$d"; cd "$d"
  printf 'pkgname=%s\npkgver=1.0\npkgrel=%s\narch=(%s)\npackage(){ install -Dm644 /dev/null "$pkgdir/usr/share/%s-%s"; echo "%s" > "$pkgdir/usr/share/%s-%s"; }\n' "$1" "$2" "$3" "$1" "$2" "${4:-payload}" "$1" "$2" > PKGBUILD
  # CARCH so the PKGINFO records the requested arch (--ignorearch would
  # stamp the host's).
  # makepkg refuses to run as root (the CI test container does); build the
  # fixture as an unprivileged user in that case.
  if (( EUID == 0 )); then
    id -u fixture >/dev/null 2>&1 || useradd -m fixture
    chmod 755 "$T/src"; chown -R fixture "$d"
    runuser -u fixture -- env CARCH=$3 makepkg -f --nodeps --ignorearch >/dev/null 2>&1
  else
    CARCH=$3 makepkg -f --nodeps --ignorearch >/dev/null 2>&1
  fi
  ls "$d"/*.pkg.tar.zst
}
A1=$(mkpkg alpha 1 any); A2=$(mkpkg alpha 2 any); B1=$(mkpkg beta 1 x86_64); C1=$(mkpkg gamma 1 aarch64)

pub() { "$ROOT/bin/publish-artifact" --remote "$REMOTE" --mirror edge --arch x86_64 "$@" >"$T/out" 2>&1; }
entries() { tar -tf "$REMOTE/edge/x86_64/omarchy.db.tar.zst" | grep '/$' | sort | tr '\n' ' '; }
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; cat "$T/out"; exit 1; }

# A temporary remote read failure must not be mistaken for a new, empty
# channel. Let later rclone operations succeed to catch the old fail-open
# path, which could otherwise publish a partial database.
mkdir -p "$T/unreadable-remote"
export REAL_RCLONE=$(command -v rclone)
cat > "$T/unreadable-remote/rclone" <<'EOF_RCLONE'
#!/bin/bash
if [[ $1 == lsf ]]; then
  echo 'simulated remote listing failure' >&2
  exit 7
fi
exec "$REAL_RCLONE" "$@"
EOF_RCLONE
chmod +x "$T/unreadable-remote/rclone"
if PATH="$T/unreadable-remote:$PATH" pub "$A1"; then
  fail "unreadable remote must stop publication"
fi
grep -q 'Cannot read remote repository' "$T/out" \
  && [[ ! -e "$REMOTE/edge/x86_64/omarchy.db.tar.zst" ]] \
  && pass "unreadable remote refused before publication" || fail "unreadable remote refusal"

pub "$A1" && [[ "$(entries)" == "alpha-1.0-1/ " ]] && [[ -f "$REMOTE/edge/x86_64/$(basename "$A1").sig" ]] \
  && pass "first publish creates db with one entry and a signature" || fail "first publish"

db_before=$(sha256sum "$REMOTE/edge/x86_64/omarchy.db.tar.zst" | awk '{print $1}')
if PATH="$T/unreadable-remote:$PATH" pub "$B1"; then
  fail "unreadable existing channel must stop publication"
fi
grep -q 'Cannot read remote repository' "$T/out" \
  && [[ "$(sha256sum "$REMOTE/edge/x86_64/omarchy.db.tar.zst" | awk '{print $1}')" == "$db_before" ]] \
  && pass "unreadable existing channel keeps its database" || fail "existing database unchanged"

sum_before=$(sha256sum "$REMOTE/edge/x86_64/$(basename "$A1")")
pub "$B1" && [[ "$(entries)" == "alpha-1.0-1/ beta-1.0-1/ " ]] && [[ "$(sha256sum "$REMOTE/edge/x86_64/$(basename "$A1")")" == "$sum_before" ]] \
  && pass "second package added incrementally; first file untouched" || fail "incremental add"

pub "$A2" && [[ "$(entries)" == "alpha-1.0-2/ beta-1.0-1/ " ]] && [[ -f "$REMOTE/edge/x86_64/$(basename "$A1")" ]] \
  && pass "new pkgrel replaces the db entry, old file remains on remote" || fail "replace entry"

# A channel only moves forward: the version it serves, or an older one, is
# never published again. A re-run of a slot that landed publishes nothing.
pub "$A2" && grep -q 'nothing published' "$T/out" && [[ "$(entries)" == "alpha-1.0-2/ beta-1.0-1/ " ]] \
  && pass "the version the channel serves is not published again" || fail "same version republished"
pub "$A1" && grep -q 'already serves alpha 1.0-2' "$T/out" && [[ "$(entries)" == "alpha-1.0-2/ beta-1.0-1/ " ]] \
  && pass "an older version never takes the channel backwards" || fail "older version published"

drop_alpha() {
  ( cd "$REMOTE/edge/x86_64" && repo-remove --quiet omarchy.db.tar.zst alpha >/dev/null 2>&1 &&
    rm omarchy.db omarchy.files && cp omarchy.db.tar.zst omarchy.db && cp omarchy.files.tar.zst omarchy.files )
  [[ "$(entries)" == "beta-1.0-1/ " ]] || fail "fixture: could not drop alpha from the db"
}

# Orphan repair: a file that reached the remote but whose db entry was lost
# (a concurrent publish overwrote the db) is fixed by publishing it again.
drop_alpha
pub "$A2" && grep -q 'identical bytes' "$T/out" && [[ "$(entries)" == "alpha-1.0-2/ beta-1.0-1/ " ]] \
  && pass "orphaned file regains its db entry on republish" || fail "orphan repair"

# Different bytes under an existing name: refused. Build alpha-2 again with
# a different payload (makepkg is reproducible, so the content must change).
A2b=$(mkpkg alpha 2 any different-payload)
[[ "$(md5sum < "$A2")" != "$(md5sum < "$A2b")" ]] || { echo "fixture: rebuilt package is byte-identical, cannot test"; exit 1; }
sum_before=$(sha256sum < "$REMOTE/edge/x86_64/$(basename "$A2")")
pub "$A2b" && grep -q 'nothing published' "$T/out" && [[ "$(sha256sum < "$REMOTE/edge/x86_64/$(basename "$A2")")" == "$sum_before" ]] \
  && pass "a rebuild of the served version is skipped, the published file untouched" || fail "served version rebuilt"
drop_alpha
if pub "$A2b"; then fail "different bytes under same filename should refuse"; else grep -q 'DIFFERENT bytes' "$T/out" && pass "different bytes under an existing name refused" || fail "wrong refusal reason"; fi
pub "$A2" || fail "fixture: could not restore alpha"

if pub "$C1"; then fail "aarch64 package into x86_64 should refuse"; else grep -q 'publishing to x86_64' "$T/out" && pass "wrong-arch package refused" || fail "wrong-arch reason"; fi

cp "$B1" "$T/renamed-1.0-1-x86_64.pkg.tar.zst"
if pub "$T/renamed-1.0-1-x86_64.pkg.tar.zst"; then fail "filename/PKGINFO mismatch should refuse"; else grep -q 'does not match PKGINFO' "$T/out" && pass "filename must match PKGINFO" || fail "mismatch reason"; fi

A3=$(mkpkg alpha 3 any); D1=$(mkpkg delta 1 any)
pub "$A1" "$A3" "$D1" && [[ "$(entries)" == "alpha-1.0-3/ beta-1.0-1/ delta-1.0-1/ " ]] \
  && pass "newer and new packages publish, the rest are dropped" || fail "mixed publish"

# db must verify: pacman can read it and each package's signature checks
gpg --batch --quiet --import <<<"$GPG_PRIVATE_KEY" 2>/dev/null || true
( cd "$REMOTE/edge/x86_64" && for f in *.pkg.tar.zst; do gpg --batch --quiet --verify "$f.sig" "$f" 2>/dev/null || { echo "FAIL: signature $f"; exit 1; }; done ) && pass "all signatures verify"

# No run uploads a database smaller than the one it pulled.
files_entries() { tar -tf "$REMOTE/edge/x86_64/omarchy.files.tar.zst" | grep -c '/$'; }
db_sums() { sha256sum < "$REMOTE/edge/x86_64/omarchy.db.tar.zst"; sha256sum < "$REMOTE/edge/x86_64/omarchy.files.tar.zst"; }
E1=$(mkpkg epsilon 1 any)

# The files database could not be downloaded: before, the failure was
# ignored and repo-add built a files database holding only this batch.
mkdir -p "$T/no-files-db"
cat > "$T/no-files-db/rclone" <<'EOF_RCLONE'
#!/bin/bash
if [[ $1 == copy* && $2 == */omarchy.files* ]]; then
  echo 'simulated download failure' >&2
  exit 7
fi
exec "$REAL_RCLONE" "$@"
EOF_RCLONE
chmod +x "$T/no-files-db/rclone"
sums_before=$(db_sums) files_count=$(files_entries)
if PATH="$T/no-files-db:$PATH" pub "$E1"; then fail "a files database that could not be pulled must stop publication"; fi
[[ "$(db_sums)" == "$sums_before" && "$(files_entries)" == "$files_count" ]] \
  && pass "a files database that could not be pulled stops publication" || fail "files database replaced"

# Whatever the cause, a database that shrank is never uploaded. This repo-add
# loses the pulled databases first, as a run that started from nothing would.
mkdir -p "$T/forgetful-repo-add"
export REAL_REPO_ADD=$(command -v repo-add)
cat > "$T/forgetful-repo-add/repo-add" <<'EOF_REPO_ADD'
#!/bin/bash
rm -f omarchy.db.tar.zst omarchy.files.tar.zst
exec "$REAL_REPO_ADD" "$@"
EOF_REPO_ADD
chmod +x "$T/forgetful-repo-add/repo-add"
if PATH="$T/forgetful-repo-add:$PATH" pub "$E1"; then fail "a database that shrank must not be uploaded"; fi
grep -q 'refusing to upload it' "$T/out" && [[ "$(db_sums)" == "$sums_before" ]] \
  && pass "a database that shrank is not uploaded" || fail "shrunken database uploaded"

# A first publish that stopped after its packages but before its database is
# retried like any other: the files already there are added to the new one.
mkdir -p "$REMOTE/rc/x86_64" && cp "$E1" "$REMOTE/rc/x86_64/"
"$ROOT/bin/publish-artifact" --remote "$REMOTE" --mirror rc --arch x86_64 "$E1" >"$T/out" 2>&1 \
  && grep -q 'identical bytes' "$T/out" && [[ "$(tar -tf "$REMOTE/rc/x86_64/omarchy.db.tar.zst" | grep '/$')" == "epsilon-1.0-1/" ]] \
  && pass "a first publish that stopped before its database can be retried" || fail "retry of a first publish"

# unpublish-packages reads the channel the same way: a listing that failed
# stops it, rather than reading as "nothing to remove" while the packages stay
# served.
unpub() { "$ROOT/bin/unpublish-packages" --remote "$REMOTE" --mirror edge --arch x86_64 "$@" >"$T/out" 2>&1; }
db_before=$(sha256sum < "$REMOTE/edge/x86_64/omarchy.db.tar.zst")
if PATH="$T/unreadable-remote:$PATH" unpub beta; then
  fail "unpublishing from an unreadable channel must fail"
fi
grep -q 'Cannot read remote repository' "$T/out" && [[ "$(sha256sum < "$REMOTE/edge/x86_64/omarchy.db.tar.zst")" == "$db_before" ]] \
  && pass "unpublish stops on an unreadable channel" || fail "unpublish on an unreadable channel"
sums_before=$(db_sums)
if PATH="$T/no-files-db:$PATH" unpub beta; then fail "unpublish must stop when the files database cannot be pulled"; fi
[[ "$(db_sums)" == "$sums_before" ]] \
  && pass "unpublish stops when the files database cannot be pulled" || fail "unpublish replaced the files database"
unpub beta && [[ "$(entries)" == "alpha-1.0-3/ delta-1.0-1/ " ]] \
  && pass "unpublish removes the named package" || fail "unpublish"

# A channel whose last packages go keeps an empty database, as repo-remove
# leaves it, and stays usable: removing what it no longer holds is a no-op,
# and a publish fills it again.
db_count() { bsdtar -tf "$REMOTE/edge/x86_64/omarchy.$1.tar.zst" | grep -c '/$' || true; }
unpub alpha delta && [[ "$(db_count db)" == 0 && "$(db_count files)" == 0 ]] \
  && pass "unpublishing a channel's last packages leaves an empty database" || fail "unpublish the last packages"
unpub alpha && grep -q 'nothing to remove' "$T/out" \
  && pass "unpublishing from an empty database removes nothing" || fail "unpublish from an empty database"
# A truncated, zero-byte database is not an empty one.
cp "$REMOTE/edge/x86_64/omarchy.db" "$T/empty.db.tar.zst"
: > "$REMOTE/edge/x86_64/omarchy.db"
if unpub alpha; then fail "a zero-byte database must not read as empty"; fi
grep -q 'zero bytes' "$T/out" && pass "a zero-byte database is refused, not read as empty" || fail "zero-byte database"
cp "$T/empty.db.tar.zst" "$REMOTE/edge/x86_64/omarchy.db"
pub "$B1" && [[ "$(entries)" == "beta-1.0-1/ " && "$(db_count files)" == 1 ]] \
  && pass "a package publishes into an empty database" || fail "publish into an empty database"

# pacman reads omarchy.db; the omarchy.db.tar.zst archive beside it is a
# separate object on the remote. A run that stopped part way through its
# upload can leave the archive behind what is served, and the next publish
# must build on what is served, not shrink it to the archive.
served() { bsdtar -tf "$REMOTE/edge/x86_64/omarchy.db" | grep '/$' | sort | tr '\n' ' '; }
cp "$REMOTE/edge/x86_64/omarchy.db.tar.zst" "$T/behind.db.tar.zst"
pub "$D1" && [[ "$(served)" == "beta-1.0-1/ delta-1.0-1/ " ]] || fail "fixture: could not publish delta"
cp "$T/behind.db.tar.zst" "$REMOTE/edge/x86_64/omarchy.db.tar.zst"
pub "$A3" && [[ "$(served)" == "alpha-1.0-3/ beta-1.0-1/ delta-1.0-1/ " ]] \
  && cmp -s "$REMOTE/edge/x86_64/omarchy.db" "$REMOTE/edge/x86_64/omarchy.db.tar.zst" \
  && pass "a publish builds on the served database when the archive is behind" || fail "served database: $(served)"

# The names pacman reads go up first. An upload that stops before the
# archives leaves them behind what is served, never ahead of it, and the next
# publish brings them back in step.
archived() { bsdtar -tf "$REMOTE/edge/x86_64/omarchy.db.tar.zst" | grep '/$' | sort | tr '\n' ' '; }
mkdir -p "$T/no-archive-upload"
cat > "$T/no-archive-upload/rclone" <<'EOF_RCLONE'
#!/bin/bash
if [[ $1 == copy && " $* " == *"omarchy.db.tar.zst"* && " $* " == *" --filter "* ]]; then
  echo 'simulated upload failure' >&2
  exit 7
fi
exec "$REAL_RCLONE" "$@"
EOF_RCLONE
chmod +x "$T/no-archive-upload/rclone"
F1=$(mkpkg phi 1 any)
if PATH="$T/no-archive-upload:$PATH" pub "$F1"; then fail "a failed archive upload must fail the publish"; fi
[[ "$(served)" == "alpha-1.0-3/ beta-1.0-1/ delta-1.0-1/ phi-1.0-1/ " && "$(archived)" == "alpha-1.0-3/ beta-1.0-1/ delta-1.0-1/ " ]] \
  && pass "a stopped upload leaves the archive behind what is served, not ahead" || fail "served $(served), archive $(archived)"
pub "$F1" && [[ "$(archived)" == "$(served)" ]] && grep -q 'already serves phi' "$T/out" \
  && pass "the next run finds the package served" || fail "rerun after a stopped upload: $(cat "$T/out")"
cp "$T/behind.db.tar.zst" "$REMOTE/edge/x86_64/omarchy.db.tar.zst"
unpub nosuch && grep -q 'nothing to remove' "$T/out" && [[ "$(archived)" == "$(served)" ]] \
  && pass "an unpublish with nothing to remove also brings the archive back in step" || fail "unpublish sync: $(archived)"
