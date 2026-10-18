#!/bin/bash
# Self-test for bin/check-dkms's plan: which packages of a channel's files
# database are kernels to build against, which are DKMS modules to build, and
# that every published DKMS package is in the registry. The build itself needs
# root and real packages; the DKMS check workflow runs it.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

entry() { # entry <name> <version> <file>...: one package in the fixture database
  local dir="$tmp/db/$1-$2" path
  mkdir -p "$dir"
  printf '%%FILENAME%%\n%s-%s-x86_64.pkg.tar.zst\n\n%%NAME%%\n%s\n\n%%SHA256SUM%%\n%s\n' "$1" "$2" "$1" "$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)" >"$dir/desc"
  {
    echo '%FILES%'
    for path in "${@:3}"; do echo "$path"; done
  } >"$dir/files"
}
entry linux-omarchy-headers 7.2.8-9 usr/lib/modules/7.2.8-9-omarchy/build/Makefile usr/lib/modules/7.2.8-9-omarchy/build/include/acpi/battery.h
entry linux-omarchy-bore-headers 7.2.8-9 usr/share/doc/linux-omarchy-bore-headers/README
entry tuxedo-drivers-nocompatcheck-dkms 4.22.1-2 usr/src/tuxedo-drivers-v4.22.1/dkms.conf usr/src/tuxedo-drivers-v4.22.1/Kbuild
entry intel-ipu7-camera 1.0.6-3 usr/src/ipu7-drivers-1.0.6/dkms.conf usr/src/vision-drivers-1.0.6/dkms.conf usr/bin/ipu7-tool
entry hyprland 0.56.2-4 usr/bin/Hyprland
bsdtar -czf "$tmp/omarchy.files" -C "$tmp/db" .

printf '%s\n' '# test registry' 'tuxedo-drivers-nocompatcheck-dkms x86_64' 'intel-ipu7-camera x86_64' 'xpadneo-dkms x86_64 aarch64' >"$tmp/registry"
export OMARCHY_DKMS_REGISTRY="$tmp/registry"

plan=$("$ROOT/bin/check-dkms" plan --arch x86_64 --files-db "$tmp/omarchy.files" 2>"$tmp/stderr") ||
  fail "a database whose DKMS packages are all listed plans cleanly: $(cat "$tmp/stderr")"
grep -qP '^kernel\tlinux-omarchy-headers\tlinux-omarchy-headers-7.2.8-9-x86_64.pkg.tar.zst\t[0-9a-f]{64}\t7.2.8-9-omarchy$' <<<"$plan" &&
  pass "a headers package with a build tree is a kernel, named by its module directory" || fail "kernel line: $plan"
! grep -q 'bore' <<<"$plan" && pass "a transitional headers package without a build tree is not a kernel" || fail "bore: $plan"
grep -qP '^dkms\ttuxedo-drivers-nocompatcheck-dkms\t\S+\t[0-9a-f]{64}\ttuxedo-drivers-v4.22.1$' <<<"$plan" &&
  pass "a package with a dkms.conf under /usr/src is a DKMS package" || fail "dkms line: $plan"
grep -qP '^dkms\tintel-ipu7-camera\t\S+\t\S+\tipu7-drivers-1.0.6,vision-drivers-1.0.6$' <<<"$plan" &&
  pass "every DKMS tree of a package is built" || fail "two trees: $plan"
! grep -q hyprland <<<"$plan" && pass "other packages are left out" || fail "hyprland: $plan"
grep -q 'xpadneo-dkms is listed for x86_64 but not published here' "$tmp/stderr" &&
  pass "a listed package the channel does not publish is only noted" || fail "note: $(cat "$tmp/stderr")"

printf '%s\n' 'intel-ipu7-camera x86_64' >"$tmp/registry"
if "$ROOT/bin/check-dkms" plan --arch x86_64 --files-db "$tmp/omarchy.files" >/dev/null 2>"$tmp/stderr"; then
  fail "an unlisted DKMS package must fail the plan"
fi
grep -q 'tuxedo-drivers-nocompatcheck-dkms ships a DKMS module for x86_64 but is not in ci/dkms-packages' "$tmp/stderr" &&
  pass "a published DKMS package missing from the registry fails the plan" || fail "unlisted: $(cat "$tmp/stderr")"
printf '%s\n' 'tuxedo-drivers-nocompatcheck-dkms x86_64' 'intel-ipu7-camera x86_64' >"$tmp/registry"

# A pull request's fresh package replaces the published one of the same name.
mkdir -p "$tmp/pkg/usr/src/tuxedo-drivers-v4.22.1" "$tmp/local"
printf 'pkgname = tuxedo-drivers-nocompatcheck-dkms\npkgver = 4.22.1-3\n' >"$tmp/pkg/.PKGINFO"
touch "$tmp/pkg/usr/src/tuxedo-drivers-v4.22.1/dkms.conf"
bsdtar -cf "$tmp/local/tuxedo-drivers-nocompatcheck-dkms-4.22.1-3-x86_64.pkg.tar.zst" --zstd -C "$tmp/pkg" .PKGINFO usr
plan=$("$ROOT/bin/check-dkms" plan --arch x86_64 --files-db "$tmp/omarchy.files" --local "$tmp/local" 2>/dev/null)
[[ $(grep -c $'^dkms\ttuxedo-drivers-nocompatcheck-dkms\t' <<<"$plan") == 1 ]] &&
  grep -qP "^dkms\ttuxedo-drivers-nocompatcheck-dkms\t$tmp/local/tuxedo-drivers-nocompatcheck-dkms-4.22.1-3-x86_64.pkg.tar.zst\t-\ttuxedo-drivers-v4.22.1$" <<<"$plan" &&
  pass "a local package replaces the published one of the same name" || fail "local override: $plan"
grep -qP '^kernel\tlinux-omarchy-headers\t' <<<"$plan" && pass "published packages without a local replacement stay" || fail "kept: $plan"

if "$ROOT/bin/check-dkms" run --arch x86_64 --channel edge >/dev/null 2>"$tmp/stderr" && ((EUID != 0)); then
  fail "run refuses to install packages without root"
fi
((EUID == 0)) || grep -q 'as root in a disposable system' "$tmp/stderr" && pass "run refuses to install packages without root" || fail "root: $(cat "$tmp/stderr")"
