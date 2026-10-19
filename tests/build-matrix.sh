#!/bin/bash
# Self-test for the runner each build gets (package_runner, and the "runner"
# field bin/build-matrix puts on every entry): aarch64 kernels on the large
# arm64 machine, everything else where it was.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
BUILD_ROOT="$ROOT"
source "$ROOT/helpers/paths.sh"
source "$ROOT/helpers/package-metadata.sh"
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

DROPLET='["self-hosted","omarchy-builder"]'
GITHUB_ARM='["ubuntu-24.04-arm"]'
KERNEL_ARM='["namespace-profile-arm64-linux-apple-12x32"]'

check() {
  local want="$1" name="$2" arch="$3" got
  got=$(package_runner "$name" "$arch")
  [[ $got == "$want" ]] || fail "$name on $arch builds on $got, expected $want"
}

for kernel in linux-omarchy-n1x linux-n1x linux-aurora linux-omarchy; do
  check "$KERNEL_ARM" "$kernel" aarch64
done
pass "an aarch64 kernel builds on the Apple-backed runner at Namespace"

for kernel in linux-omarchy linux-omarchy-bore linux-omarchy-eevdf; do
  check "$DROPLET" "$kernel" x86_64
done
pass "an x86_64 kernel stays on the droplet pool"

check "$GITHUB_ARM" linux-aarch64-pkgbase-shim aarch64
check "$GITHUB_ARM" linux-firmware-cirrus-dx13260 aarch64
pass "a linux-* package that is no kernel stays on GitHub's arm64 runner"

for package in omarchy-settings gliff hyprland nvidia-open-dkms alinux; do
  check "$GITHUB_ARM" "$package" aarch64
  check "$DROPLET" "$package" x86_64
done
pass "every other package builds where it did"

# Each value has to be what runs-on takes: a JSON list of labels.
for runner in "$DROPLET" "$GITHUB_ARM" "$KERNEL_ARM"; do
  jq -e 'type == "array" and length > 0 and all(type == "string")' <<<"$runner" >/dev/null || fail "not a list of labels: $runner"
done
pass "every runner is a JSON list of labels"

# The matrix carries the rule: every entry names its runner, and it is the
# one package_runner gives for that package and architecture.
matrix=$("$ROOT/bin/build-matrix" linux-aurora linux-aarch64-pkgbase-shim omarchy-settings)
[[ $(jq '.include | length' <<<"$matrix") -ge 4 ]] || fail "matrix: $matrix"
while read -r package arch runner; do
  [[ $runner == "$(package_runner "$package" "$arch")" ]] || fail "matrix entry $package $arch has runner $runner"
done < <(jq -r '.include[] | "\(.package) \(.arch) \(.runner)"' <<<"$matrix")
[[ $(jq -r '.include[] | select(.package == "linux-aurora") | .runner' <<<"$matrix") == "$KERNEL_ARM" ]] || fail "linux-aurora in the matrix: $matrix"
pass "bin/build-matrix puts the runner on every entry"

# A directory name reaches job names, artifact names, API queries, paths and,
# before workflows passed values through env, shell commands on the builder
# host. Only names makepkg accepts for a package pass; any other fails the
# whole matrix, read from arguments or stdin, and even when the directory
# exists with a recipe in it.
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/helpers"
cp "$ROOT/bin/build-matrix" "$fixture/bin/"
cp "$ROOT"/helpers/*.sh "$fixture/helpers/"
recipe() { # recipe <directory name>: a recipe that builds for edge
  mkdir -p "$fixture/pkgbuilds/$1/.omarchy" || return 0
  printf 'pkgname=x\npkgver=1\npkgrel=1\narch=(any)\n' >"$fixture/pkgbuilds/$1/PKGBUILD"
  echo '{"source": "local"}' >"$fixture/pkgbuilds/$1/.omarchy/package.json"
}
# In en_US.UTF-8, where the system has it, [a-z] in a bash regex matches "ä".
wide=C.UTF-8
if locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'; then
  wide=en_US.UTF-8
fi
for name in 'flea";F1_INJECTED=1;$(date)||:;:"' 'x$(touch pwned)' 'x";touch pwned;"' "x'y" 'x`id`' 'a b' 'a;b' 'a&b' 'a|b' 'a>b' 'a\b' \
  -a .a .. ../bin a/b 'a*' 'a?b' '[a]' '%a' 'a:b' 'a~b' ':a' '::warning::x' '##[error]x' $'a\nb' $'a\r' $'a\tb' é hyprländ; do
  [[ $name == *[/]* || $name == .. ]] || recipe "$name"
  if out=$(LC_ALL=$wide "$fixture/bin/build-matrix" "$name" 2>"$fixture/err"); then
    fail "build-matrix accepted $(printf %q "$name"): $out"
  fi
  [[ -z $out ]] || fail "build-matrix printed a matrix for $(printf %q "$name"): $out"
  grep -q '^build-matrix: refusing package directory ' "$fixture/err" || fail "no refusal for $(printf %q "$name"): $(cat "$fixture/err")"
  ! grep -qE '^::|##\[' "$fixture/err" || fail "the refusal repeats a workflow command: $(cat "$fixture/err")"
done
pass "a directory name makepkg would refuse fails the matrix"

recipe hyprland
if out=$(printf '%s\n' hyprland 'x$(touch pwned)' | "$fixture/bin/build-matrix" 2>/dev/null); then
  fail "build-matrix accepted a refused name among good ones on stdin: $out"
fi
[[ -z $out ]] || fail "build-matrix printed a partial matrix: $out"
pass "one refused name on stdin fails the whole matrix, it is not skipped"

for name in libc++ python-foo.bar pkg@1 a_b A1 7zip; do recipe "$name"; done
matrix=$(printf '%s\n' libc++ python-foo.bar pkg@1 a_b A1 7zip '' | "$fixture/bin/build-matrix")
[[ $(jq -r '[.include[].package] | join(" ")' <<<"$matrix") == "libc++ python-foo.bar pkg@1 a_b A1 7zip" ]] ||
  fail "valid names: $matrix"
pass "every name makepkg accepts still plans, and an empty line is skipped"
