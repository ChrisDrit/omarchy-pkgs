#!/bin/bash
# Self-test for bin/check-dkms's plan: which packages of a channel are kernels
# and DKMS modules, which kernel/module pairs a check builds (only those that
# touch a changed package), and that every published DKMS package is in the
# registry. The build itself needs root and real packages; the DKMS check
# workflow runs it.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

entry() { # entry <db> <name> <version> <file>...: one package in a fixture database
  local dir="$tmp/$1/$2-$3" path
  mkdir -p "$dir"
  printf '%%FILENAME%%\n%s-%s-x86_64.pkg.tar.zst\n\n%%NAME%%\n%s\n\n%%VERSION%%\n%s\n\n%%SHA256SUM%%\n%s\n' \
    "$2" "$3" "$2" "$3" "$(printf '%s' "$2$3" | sha256sum | cut -d' ' -f1)" >"$dir/desc"
  {
    echo '%FILES%'
    for path in "${@:4}"; do echo "$path"; done
  } >"$dir/files"
}
channel() { # channel <db>: pack a fixture database
  bsdtar -czf "$tmp/$1.files" -C "$tmp/$1" .
}
for db in edge rc; do
  entry $db linux-omarchy-bore-headers 7.2.8-9 usr/share/doc/linux-omarchy-bore-headers/README
  entry $db intel-ipu7-camera 1.0.6-3 usr/src/ipu7-drivers-1.0.6/dkms.conf usr/src/vision-drivers-1.0.6/dkms.conf usr/bin/ipu7-tool
  entry $db hyprland 0.56.2-4 usr/bin/Hyprland
done
entry rc linux-omarchy-headers 7.2.8-8 usr/lib/modules/7.2.8-8-omarchy/build/Makefile
entry rc tuxedo-drivers-nocompatcheck-dkms 4.22.1-2 usr/src/tuxedo-drivers-v4.22.1/dkms.conf
entry edge linux-omarchy-headers 7.2.8-9 usr/lib/modules/7.2.8-9-omarchy/build/Makefile usr/lib/modules/7.2.8-9-omarchy/build/include/acpi/battery.h
entry edge tuxedo-drivers-nocompatcheck-dkms 4.22.1-2 usr/src/tuxedo-drivers-v4.22.1/dkms.conf usr/src/tuxedo-drivers-v4.22.1/Kbuild
channel edge
channel rc

printf '%s\n' '# test registry' 'tuxedo-drivers-nocompatcheck-dkms x86_64' 'intel-ipu7-camera x86_64' 'xpadneo-dkms x86_64 aarch64' >"$tmp/registry"
export OMARCHY_DKMS_REGISTRY="$tmp/registry"
check() { "$ROOT/bin/check-dkms" plan --arch x86_64 --files-db "$tmp/edge.files" "$@" 2>"$tmp/stderr"; }

plan=$(check) || fail "a database whose DKMS packages are all listed plans cleanly: $(cat "$tmp/stderr")"
grep -qP '^kernel\tlinux-omarchy-headers\t7.2.8-9\t7.2.8-9-omarchy$' <<<"$plan" &&
  pass "a headers package with a build tree is a kernel, named by its module directory" || fail "kernel: $plan"
! grep -q bore <<<"$plan" && pass "a transitional headers package without a build tree is not a kernel" || fail "bore: $plan"
grep -qP '^dkms\tintel-ipu7-camera\t1.0.6-3\tipu7-drivers-1.0.6,vision-drivers-1.0.6$' <<<"$plan" &&
  pass "a package with dkms.conf trees under /usr/src is a DKMS package" || fail "dkms: $plan"
! grep -q hyprland <<<"$plan" && pass "other packages are left out" || fail "hyprland: $plan"
[[ $(grep -c '^pair' <<<"$plan") == 3 ]] && grep -qP '^pair\tlinux-omarchy-headers 7.2.8-9-omarchy\tintel-ipu7-camera vision-drivers-1.0.6$' <<<"$plan" &&
  pass "with nothing to compare against, every kernel/module pair is checked" || fail "all pairs: $plan"
grep -q 'xpadneo-dkms is listed for x86_64 but not published here' "$tmp/stderr" &&
  pass "a listed package the channel does not publish is only noted" || fail "note: $(cat "$tmp/stderr")"

# A promotion checks the pairs that touch a version the target lacks.
plan=$(check --since-db "$tmp/rc.files")
[[ $(grep -c '^pair' <<<"$plan") == 3 ]] && grep -q 'linux-omarchy-headers 7.2.8-9-omarchy' <<<"$plan" &&
  pass "a new kernel is checked against every module" || fail "new kernel: $plan"
plan=$("$ROOT/bin/check-dkms" plan --arch x86_64 --files-db "$tmp/edge.files" --since-db "$tmp/edge.files" 2>/dev/null)
grep -qx 'nothing to check' <<<"$plan" && ! grep -q '^pair' <<<"$plan" &&
  pass "a promotion that moves no kernel or module checks nothing" || fail "unchanged: $plan"

printf '%s\n' 'intel-ipu7-camera x86_64' >"$tmp/registry"
if check >/dev/null; then
  fail "an unlisted DKMS package must fail the plan"
fi
grep -q 'tuxedo-drivers-nocompatcheck-dkms ships a DKMS module for x86_64 but is not in ci/dkms-packages' "$tmp/stderr" &&
  pass "a published DKMS package missing from the registry fails the plan" || fail "unlisted: $(cat "$tmp/stderr")"
printf '%s\n' 'tuxedo-drivers-nocompatcheck-dkms x86_64' 'intel-ipu7-camera x86_64' >"$tmp/registry"

# A pull request's fresh package replaces the published one and is what the
# check is about.
package() { # package <dir> <name> <version> <arch> <path>...
  local root="$tmp/pkgroot-$2"
  rm -rf "$root"
  mkdir -p "$root"
  printf 'pkgname = %s\npkgver = %s\narch = %s\n' "$2" "$3" "$4" >"$root/.PKGINFO"
  for path in "${@:5}"; do mkdir -p "$root/${path%/*}"; touch "$root/$path"; done
  mkdir -p "$1"
  bsdtar -cf "$1/$2-$3-$4.pkg.tar.zst" --zstd -C "$root" .PKGINFO usr
}
package "$tmp/local" tuxedo-drivers-nocompatcheck-dkms 4.22.1-3 x86_64 usr/src/tuxedo-drivers-v4.22.1/dkms.conf
package "$tmp/local" yt6801-dkms 1.0.34-2 aarch64 usr/src/yt6801-1.0.34/dkms.conf
plan=$(check --local "$tmp/local") || fail "a local DKMS package plans: $(cat "$tmp/stderr")"
grep -qP '^dkms\ttuxedo-drivers-nocompatcheck-dkms\t4.22.1-3\t' <<<"$plan" && [[ $(grep -c $'^dkms\ttuxedo' <<<"$plan") == 1 ]] &&
  pass "a local package replaces the published one of the same name" || fail "replace: $plan"
[[ $(grep -c '^pair' <<<"$plan") == 1 ]] && grep -qP '^pair\tlinux-omarchy-headers 7.2.8-9-omarchy\ttuxedo-drivers-nocompatcheck-dkms tuxedo-drivers-v4.22.1$' <<<"$plan" &&
  pass "a local DKMS package is checked against every kernel, and only it" || fail "local pairs: $plan"
! grep -q yt6801 <<<"$plan" && pass "a local package for another architecture is ignored" || fail "arch: $plan"

package "$tmp/local-kernel" linux-omarchy-headers 7.2.9-1 x86_64 usr/lib/modules/7.2.9-1-omarchy/build/Makefile
plan=$(check --local "$tmp/local-kernel")
[[ $(grep -c '^pair' <<<"$plan") == 3 ]] && grep -q 'linux-omarchy-headers 7.2.9-1-omarchy' <<<"$plan" &&
  pass "a local kernel is checked against every module" || fail "local kernel: $plan"

package "$tmp/local-lost" linux-omarchy-headers 7.2.9-1 x86_64 usr/share/doc/linux-omarchy-headers/README
if check --local "$tmp/local-lost" >/dev/null; then
  fail "a local kernel that lost its build tree must not let the published one stand in"
fi
grep -q "the local linux-omarchy-headers is a 'other' package, but the published one is 'kernel'" "$tmp/stderr" &&
  pass "a local package that lost its tree is an error, not the published one" || fail "lost: $(cat "$tmp/stderr")"

mkdir -p "$tmp/empty"
if check --local "$tmp/empty" >/dev/null; then fail "an empty --local must fail"; fi
grep -q 'holds no package for x86_64' "$tmp/stderr" && pass "an empty --local is an error" || fail "empty: $(cat "$tmp/stderr")"
if check --local "$tmp/missing" >/dev/null; then fail "a missing --local must fail"; fi
grep -q 'is not a directory' "$tmp/stderr" && pass "a missing --local is an error" || fail "missing: $(cat "$tmp/stderr")"

# kernels= limits a module to the kernels it is installed with.
entry scoped linux-aurora-headers 7.1.12-2 usr/lib/modules/7.1.12-2-ARCH/build/Makefile
entry scoped linux-omarchy-headers 7.2.8-13 usr/lib/modules/7.2.8-13-omarchy/build/Makefile
entry scoped omarchy-ane-dkms 0.4.9-1 usr/src/omarchy-ane-0.4.9/dkms.conf
entry scoped xpadneo-dkms 0.10.4-1 usr/src/hid-xpadneo-v0.10.4/dkms.conf
channel scoped
printf '%s\n' 'omarchy-ane-dkms aarch64 kernels=linux-aurora-headers' 'xpadneo-dkms x86_64 aarch64' >"$tmp/registry"
plan=$("$ROOT/bin/check-dkms" plan --arch aarch64 --files-db "$tmp/scoped.files" 2>/dev/null)
grep -qP '^pair\tlinux-aurora-headers 7.1.12-2-ARCH\tomarchy-ane-dkms ' <<<"$plan" &&
  ! grep -qP '^pair\tlinux-omarchy-headers \S+\tomarchy-ane-dkms ' <<<"$plan" &&
  [[ $(grep -c $'^pair\t.*xpadneo-dkms' <<<"$plan") == 2 ]] &&
  pass "a module limited to some kernels is only built against those" || fail "scope: $plan"
printf '%s\n' 'tuxedo-drivers-nocompatcheck-dkms x86_64' 'intel-ipu7-camera x86_64' >"$tmp/registry"

# repo= packages come from an Arch repository's files database. They pair
# whenever a kernel changes and never count as a change of their own.
entry extra v4l2loopback-dkms 0.15.4-2 usr/src/v4l2loopback-0.15.4/dkms.conf
entry extra hyprland-git 1-1 usr/bin/Hyprland
channel extra
printf '%s\n' 'tuxedo-drivers-nocompatcheck-dkms x86_64' 'intel-ipu7-camera x86_64' 'v4l2loopback-dkms x86_64 repo=extra' >"$tmp/registry"
repo=(--repo-files-db "extra=$tmp/extra.files")
plan=$(check "${repo[@]}") || fail "a repo= package plans: $(cat "$tmp/stderr")"
grep -qP '^dkms\tv4l2loopback-dkms\t0.15.4-2\tv4l2loopback-0.15.4$' <<<"$plan" && ! grep -q hyprland-git <<<"$plan" &&
  grep -qP '^pair\tlinux-omarchy-headers 7.2.8-9-omarchy\tv4l2loopback-dkms v4l2loopback-0.15.4$' <<<"$plan" &&
  pass "a repo= package is read from its repository and checked against every kernel" || fail "repo: $plan"
! grep -q 'v4l2loopback-dkms is listed for x86_64 but not published here' "$tmp/stderr" &&
  pass "a repo= package is not reported as missing from this repository" || fail "repo note: $(cat "$tmp/stderr")"
plan=$(check "${repo[@]}" --since-db "$tmp/edge.files")
grep -qx 'nothing to check' <<<"$plan" &&
  pass "a promotion that moves no kernel does not check repo= packages" || fail "repo unchanged: $plan"
plan=$(check "${repo[@]}" --since-db "$tmp/rc.files")
grep -qP '^pair\tlinux-omarchy-headers 7.2.8-9-omarchy\tv4l2loopback-dkms ' <<<"$plan" &&
  pass "a promotion that moves a kernel checks it against repo= packages" || fail "repo kernel: $plan"
plan=$(check "${repo[@]}" --local "$tmp/local-kernel")
grep -qP '^pair\tlinux-omarchy-headers 7.2.9-1-omarchy\tv4l2loopback-dkms ' <<<"$plan" &&
  pass "a pull request's kernel is checked against repo= packages" || fail "repo local kernel: $plan"
plan=$(check --local "$tmp/local") || fail "a pull request without a kernel must not need repository databases: $(cat "$tmp/stderr")"
! grep -q v4l2loopback <<<"$plan" &&
  pass "a pull request without a kernel neither downloads nor checks repo= packages" || fail "repo not needed: $plan"
plan=$(check "${repo[@]}" --from-repos)
[[ $(grep -c '^pair' <<<"$plan") == 1 ]] && grep -q 'v4l2loopback-dkms' <<<"$plan" &&
  pass "--from-repos checks only repo= packages, against every kernel" || fail "from-repos: $plan"
if check >/dev/null; then fail "a whole-channel plan without the repository's files database must fail"; fi
grep -q "no files database given for v4l2loopback-dkms's repository, extra" "$tmp/stderr" &&
  pass "a missing repository database is an error" || fail "no repo db: $(cat "$tmp/stderr")"
printf '%s\n' 'tuxedo-drivers-nocompatcheck-dkms x86_64' 'intel-ipu7-camera x86_64' 'nosuch-dkms x86_64 repo=extra' >"$tmp/registry"
if check "${repo[@]}" >/dev/null; then fail "a repo= package its repository lacks must fail"; fi
grep -q 'nosuch-dkms is listed as coming from extra, but extra has no DKMS package of that name' "$tmp/stderr" &&
  pass "a repo= package missing from its repository is an error" || fail "repo missing: $(cat "$tmp/stderr")"
printf '%s\n' 'tuxedo-drivers-nocompatcheck-dkms x86_64' 'intel-ipu7-camera x86_64' 'v4l2loopback-dkms x86_64 repo=extra' >"$tmp/registry"
package "$tmp/local-own" v4l2loopback-dkms 0.15.5-1 x86_64 usr/src/v4l2loopback-0.15.5/dkms.conf
package "$tmp/local-own" linux-omarchy-headers 7.2.9-1 x86_64 usr/lib/modules/7.2.9-1-omarchy/build/Makefile
plan=$(check "${repo[@]}" --local "$tmp/local-own")
grep -qP '^dkms\tv4l2loopback-dkms\t0.15.5-1\t' <<<"$plan" && [[ $(grep -c $'^dkms\tv4l2loopback-dkms' <<<"$plan") == 1 ]] &&
  grep -q 'v4l2loopback-dkms is built here too' "$tmp/stderr" &&
  pass "this repository's own copy of a repo= package is the one checked" || fail "own copy: $plan $(cat "$tmp/stderr")"
printf '%s\n' 'tuxedo-drivers-nocompatcheck-dkms x86_64' 'intel-ipu7-camera x86_64' >"$tmp/registry"

# A pull request that adds a DKMS recipe is checked before it publishes, even
# though master's registry does not list it yet.
package "$tmp/local-new" hid-nintendo2-dkms 0.1.0-1 x86_64 usr/src/hid-nintendo2-0.1.0/dkms.conf
plan=$(check --local "$tmp/local-new") || fail "an unlisted fresh DKMS package plans: $(cat "$tmp/stderr")"
[[ $(grep -c '^pair' <<<"$plan") == 1 ]] && grep -qP '^pair\tlinux-omarchy-headers 7.2.8-9-omarchy\thid-nintendo2-dkms hid-nintendo2-0.1.0$' <<<"$plan" &&
  grep -q 'hid-nintendo2-dkms is not in ci/dkms-packages yet' "$tmp/stderr" &&
  pass "an unlisted fresh DKMS package is checked against every kernel" || fail "new recipe: $plan $(cat "$tmp/stderr")"

# needs: whether a build holds anything to check, decided before any container.
package "$tmp/local-plain" hyprland 0.56.2-5 x86_64 usr/bin/Hyprland
"$ROOT/bin/check-dkms" needs --arch x86_64 --local "$tmp/local-plain" >/dev/null &&
  fail "a build without kernels or DKMS packages needs no check" || pass "a build without kernels or DKMS packages needs no check"
"$ROOT/bin/check-dkms" needs --arch x86_64 --local "$tmp/local" | grep -q 'tuxedo-drivers-nocompatcheck-dkms-4.22.1-3-x86_64.pkg.tar.zst (dkms)' &&
  pass "a build with a DKMS package needs a check, and says which" || fail "needs dkms"
"$ROOT/bin/check-dkms" needs --arch x86_64 --local "$tmp/local-kernel" | grep -q '(kernel)' &&
  pass "a build with a kernel needs a check" || fail "needs kernel"
"$ROOT/bin/check-dkms" needs --arch aarch64 --local "$tmp/local-kernel" >/dev/null &&
  fail "another architecture's kernel needs no check" || pass "another architecture's kernel needs no check"

# run installs packages, so it must refuse to start without root. Checked only
# when not root: as root it would really install them.
if ((EUID != 0)); then
  if "$ROOT/bin/check-dkms" run --arch x86_64 --channel edge >/dev/null 2>"$tmp/stderr"; then fail "run must refuse without root"; fi
  grep -q 'as root in a disposable system' "$tmp/stderr" && pass "run refuses to install packages without root" || fail "root: $(cat "$tmp/stderr")"
fi
