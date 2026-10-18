#!/bin/bash
# Self-test for bin/build-artifacts: what a pull request build would publish,
# for the DKMS check. A planned package with no artifact in the run built
# nothing (edge already holds it); a reused artifact must still exist; a
# download, extraction or copy that fails, or an artifact with no package,
# fails the collection. gh is a stub that answers from fixtures.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# A head commit with three recipes.
git init -q "$tmp/repo"
for p in linux-omarchy xpadneo-dkms hyprland; do
  mkdir -p "$tmp/repo/pkgbuilds/$p"
  echo "pkgname=$p" >"$tmp/repo/pkgbuilds/$p/PKGBUILD"
done
git -C "$tmp/repo" add -A
git -C "$tmp/repo" -c user.name=t -c user.email=t@t commit -qm head
head=$(git -C "$tmp/repo" rev-parse HEAD)
tree() { git -C "$tmp/repo" rev-parse "$head:pkgbuilds/$1"; }

# gh api, answered from $FAKE_GH: runs/<id>.json, artifacts/<id>.zip and
# named/<label>.json. --jq applies the expression the way gh does.
mkdir -p "$tmp/bin" "$tmp/gh/runs" "$tmp/gh/artifacts" "$tmp/gh/named"
cat >"$tmp/bin/gh" <<'GH'
#!/bin/bash
set -euo pipefail
path="" expr=""
while (($#)); do
  case $1 in
    --jq) expr=$2; shift 2 ;;
    repos/*) path=$1; shift ;;
    *) shift ;;
  esac
done
case $path in
  */actions/runs/*/artifacts) file=$FAKE_GH/runs/$(cut -d/ -f6 <<<"$path").json ;;
  */actions/artifacts/*/zip) cat "$FAKE_GH/artifacts/$(cut -d/ -f6 <<<"$path").zip"; exit ;;
  */actions/artifacts\?name=*) label=${path#*name=}; file=$FAKE_GH/named/${label%%&*}.json ;;
  *) echo "gh stub: unexpected $path" >&2; exit 1 ;;
esac
[[ -f $file ]] || { echo "gh stub: HTTP 404" >&2; exit 1; }
if [[ -n $expr ]]; then jq -r "$expr" "$file"; else cat "$file"; fi
GH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" FAKE_GH="$tmp/gh" GITHUB_REPOSITORY=omacom/omarchy-pkgs

# artifact <id> <tar|bare|empty|corrupt> <file>...: an artifact's zip.
artifact() {
  local id=$1 form=$2 dir="$tmp/a$1" f
  mkdir -p "$dir/files" "$dir/zip"
  for f in "${@:3}"; do echo "$f" >"$dir/files/$f"; done
  case $form in
    tar) tar -cf "$dir/zip/packages.tar" -C "$dir/files" "${@:3}" ;;
    bare) cp "$dir/files"/* "$dir/zip/" ;;
    empty) tar -cf "$dir/zip/packages.tar" -T /dev/null ;;
    corrupt) echo "not a tar" >"$dir/zip/packages.tar" ;;
  esac
  (cd "$dir/zip" && bsdtar -a -cf "$tmp/gh/artifacts/$id.zip" ./*)
}
artifact 11 tar linux-omarchy-7.2.8-10-x86_64.pkg.tar.zst linux-omarchy-headers-7.2.8-10-x86_64.pkg.tar.zst
artifact 12 bare xpadneo-dkms-0.9.8-1-any.pkg.tar.zst
artifact 13 empty
artifact 14 corrupt
artifact 15 tar 'linux-omarchy-1:7.2.8-10-aarch64.pkg.tar.zst'

run_json() { # run_json <run> <name=id>...: a run's artifact listing
  local pair
  for pair in "${@:2}"; do
    jq -n --arg n "${pair%=*}" --argjson i "${pair#*=}" '{name: $n, id: $i, expired: false}'
  done | jq -s '{artifacts: .}' >"$tmp/gh/runs/$1.json"
}
matrix() { # matrix <package:arch>...
  printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0) | split(":") | {package: .[0], arch: .[1]}) | {include: .}'
}
collect() { # collect <run> <matrix> <reused json>
  rm -rf "$tmp/out"
  (cd "$tmp/repo" && "$ROOT/bin/build-artifacts" "$tmp/out" "$1" "$2" "$3" "$head") >"$tmp/stdout" 2>"$tmp/stderr"
}
outfiles() { ls "$tmp/out" 2>/dev/null | sort | tr '\n' ' '; }

k=linux-omarchy-x86_64-$(tree linux-omarchy)
run_json 1 "$k=11" "hyprland-x86_64-$(tree linux-omarchy)=12"
collect 1 "$(matrix linux-omarchy:x86_64 hyprland:x86_64)" '[]' || fail "a run's own artifacts collect: $(cat "$tmp/stderr")"
[[ $(outfiles) == "linux-omarchy-7.2.8-10-x86_64.pkg.tar.zst linux-omarchy-headers-7.2.8-10-x86_64.pkg.tar.zst " ]] &&
  pass "a planned package's artifact from this run is unpacked, and only by its own label" || fail "own: $(outfiles)"
grep -qF "hyprland-x86_64-$(tree hyprland): nothing built (edge already holds this version)" "$tmp/stdout" &&
  pass "a planned package with no artifact in the run built nothing" || fail "held: $(cat "$tmp/stdout")"

x=xpadneo-dkms-x86_64-$(tree xpadneo-dkms)
jq -n --arg n "$x" '{artifacts: [{name: $n, id: 99, expired: true, created_at: "2026-10-18T10:00:00Z"}, {name: $n, id: 12, expired: false, created_at: "2026-10-17T10:00:00Z"}]}' >"$tmp/gh/named/$x.json"
collect 1 "$(matrix linux-omarchy:x86_64)" "[\"$x\"]" || fail "a reused artifact collects: $(cat "$tmp/stderr")"
grep -q '^xpadneo-dkms-0.9.8-1-any.pkg.tar.zst$' <(ls "$tmp/out") &&
  pass "a reused artifact from an earlier run is collected too, past an expired one, bare files included" || fail "reused: $(outfiles)"

gone=linux-omarchy-aarch64-$(tree linux-omarchy)
echo '{"artifacts": []}' >"$tmp/gh/named/$gone.json"
! collect 1 "$(matrix)" "[\"$gone\"]" && grep -q "reused artifact $gone, which no longer exists" "$tmp/stderr" &&
  pass "a reused artifact that is gone fails, it does not pass as nothing built" || fail "gone: $(cat "$tmp/stderr")"

jq -n --arg n "$gone" '{artifacts: [{name: $n, id: 15, expired: false, created_at: "2026-10-18T10:00:00Z"}]}' >"$tmp/gh/named/$gone.json"
collect 1 "$(matrix)" "[\"$gone\"]" && [[ -f "$tmp/out/linux-omarchy-1:7.2.8-10-aarch64.pkg.tar.zst" ]] &&
  pass "a package with an epoch comes through packages.tar under its own name" || fail "epoch: $(outfiles) $(cat "$tmp/stderr")"

run_json 2 "$k=13"
! collect 2 "$(matrix linux-omarchy:x86_64)" '[]' && grep -q "artifact $k holds no package" "$tmp/stderr" &&
  pass "an artifact with no package fails" || fail "empty: $(cat "$tmp/stderr")"
run_json 3 "$k=14"
! collect 3 "$(matrix linux-omarchy:x86_64)" '[]' && grep -q "cannot unpack artifact $k" "$tmp/stderr" &&
  pass "an artifact whose packages.tar does not unpack fails" || fail "corrupt: $(cat "$tmp/stderr")"
run_json 4 "$k=404"
! collect 4 "$(matrix linux-omarchy:x86_64)" '[]' && grep -q "cannot download artifact $k" "$tmp/stderr" &&
  pass "a download that fails fails the collection" || fail "download: $(cat "$tmp/stderr")"
! collect 5 "$(matrix linux-omarchy:x86_64)" '[]' && grep -q "cannot list run 5's artifacts" "$tmp/stderr" &&
  pass "a run whose artifacts cannot be listed fails" || fail "listing: $(cat "$tmp/stderr")"
! collect 1 "$(matrix no-such-recipe:x86_64)" '[]' && grep -q "no pkgbuilds/no-such-recipe at $head" "$tmp/stderr" &&
  pass "a planned package missing from the head fails" || fail "recipe: $(cat "$tmp/stderr")"

# A copy that fails stops the collection, it does not leave a package out.
mkdir -p "$tmp/ro"
chmod a-w "$tmp/ro"
if [[ $(id -u) != 0 ]]; then
  ! (cd "$tmp/repo" && "$ROOT/bin/build-artifacts" "$tmp/ro" 1 "$(matrix linux-omarchy:x86_64)" '[]' "$head") 2>"$tmp/stderr" &&
    grep -q "cannot copy linux-omarchy-.* from artifact $k" "$tmp/stderr" &&
    pass "a package that cannot be copied fails the collection" || fail "copy: $(cat "$tmp/stderr")"
fi
chmod u+w "$tmp/ro"
