#!/bin/bash
#
# Runs inside an unprivileged archlinux:base container started by
# rebuild/omarchy-repro, with the job directory mounted at /job.
#
# Creates the build root from exactly the packages in /job/files, applies
# what build/Dockerfile does to the builder image, runs makepkg as "builder"
# the way build/build.sh does, copies the packages it made to /job/outputs
# and removes the root again. Package scriptlets and hooks run here, against
# the container's own /dev, /proc and /sys, never the host's.
#
# Environment (validated by omarchy-repro): STARTDIR BUILDDIR BUILDDATE
# PACKAGER OPTIONS BUILDENV NOCHECK OWNER (uid:gid that gets the outputs)

set -uo pipefail

R=/job/root

# The state goes to /job/state, outside the root: nothing that runs in the
# root (scriptlets, makepkg, the package's own build) can write it.
step() {
  echo "== $*"
  echo "$*" >/job/state
}

fail() {
  echo "INNER-FAIL $1"
  echo "failed $1" >/job/state
  exit "${2:-1}"
}

# The container has its own mount namespace, so a lazy unmount here can't
# reach the host; one at a time, so a busy /dev doesn't keep /proc mounted.
finish() {
  local m
  for m in dev sys proc; do
    umount -R -l "$R/$m" 2>/dev/null
  done
  rm -rf --one-file-system "$R"
}
trap finish EXIT

step "creating root"
mkdir -p "$R/var/lib/pacman" "$R/etc" "$R/proc" "$R/sys" "$R/dev" /job/outputs
if ! mount -t proc proc "$R/proc" || ! mount --bind /sys "$R/sys" || ! mount --rbind /dev "$R/dev"; then
  fail "verifier: cannot mount proc, sys and dev in the root"
fi
printf '[options]\nArchitecture = auto\nSigLevel = Never\n' >/tmp/pacman.conf
mapfile -t files </job/files
if ! pacman --root "$R" --config /tmp/pacman.conf --noconfirm -U --overwrite '*' "${files[@]}"; then
  fail "verifier: pacman could not create the root"
fi

# What the builder image does on top of pacstrap (build/Dockerfile).
cat >"$R/etc/pacman.conf" <<'EOF'
[options]
HoldPkg = pacman glibc
Architecture = auto
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
EOF
if ! {
  echo "en_US.UTF-8 UTF-8" >"$R/etc/locale.gen" &&
    echo "LANG=en_US.UTF-8" >"$R/etc/locale.conf" &&
    ln -sf /usr/lib/os-release "$R/etc/os-release" &&
    chroot "$R" locale-gen >/dev/null &&
    chroot "$R" useradd -m -G wheel -s /bin/bash builder &&
    echo "builder ALL=(ALL) NOPASSWD: ALL" >>"$R/etc/sudoers" &&
    sed -i 's/^#MAKEFLAGS=.*/MAKEFLAGS="-j$(nproc)"/' "$R/etc/makepkg.conf" &&
    sed -i 's/^COMPRESSZST=.*/COMPRESSZST=(zstd -c -z -q --threads=0 -)/' "$R/etc/makepkg.conf" &&
    sed -i "s|^PKGEXT=.*|PKGEXT='.pkg.tar.zst'|" "$R/etc/makepkg.conf" &&
    printf '#!/bin/bash\nexec /usr/bin/pacman --ask 4 "$@"\n' >"$R/usr/local/bin/pacman-for-makepkg" &&
    chmod +x "$R/usr/local/bin/pacman-for-makepkg" &&
    cp -L /etc/resolv.conf "$R/etc/resolv.conf"
}; then
  fail "verifier: cannot set up the builder image state"
fi

# The builder never exports SOURCE_DATE_EPOCH, so makepkg makes one up and
# keeps REPRODUCIBLE=0. Exporting it would switch makepkg to its other mode,
# which touches every source file after prepare(). makepkg reads its config
# after it has set the epoch, so the recorded one goes there instead.
if ! {
  printf 'PACKAGER=%q\n' "$PACKAGER"
  printf 'OPTIONS=(%s)\n' "$OPTIONS"
  printf 'BUILDENV=(%s)\n' "$BUILDENV"
  printf 'SOURCE_DATE_EPOCH=%s\n' "$BUILDDATE"
  if [[ $BUILDDIR != "$STARTDIR" ]]; then
    printf 'BUILDDIR=%q\n' "$BUILDDIR"
  fi
} >>"$R/etc/makepkg.conf"; then
  fail "verifier: cannot write makepkg.conf"
fi

if ! mkdir -p "$R$STARTDIR" "$R$BUILDDIR" "$R/build" ||
  ! cp -a /job/recipe/. "$R$STARTDIR/" ||
  ! cp -a /job/build/. "$R/build/" ||
  ! chroot "$R" chown -R builder:builder /src "$BUILDDIR" /home/builder; then
  fail "verifier: cannot put the recipe in place"
fi

# As builder, with the environment Docker gives a USER builder container:
# HOME and HOSTNAME set, USER and LOGNAME not. In a PID and mount namespace
# of its own with a fresh /proc, so nothing in the build (which can sudo, as
# in the builder image) reaches /job through /proc/1/root.
as_builder() {
  unshare --pid --mount --fork --mount-proc="$R/proc" \
    chroot "$R" setpriv --reuid=builder --regid=builder --init-groups \
    env -i HOME=/home/builder HOSTNAME="$(hostname)" LANG=en_US.UTF-8 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    PACMAN=/usr/local/bin/pacman-for-makepkg \
    bash -c "cd \"$STARTDIR\" && $1"
}

step "importing keys"
as_builder '
  /build/import-gpg-keys.sh
  for key in $(bash -c "source PKGBUILD 2>/dev/null; echo \"\${validpgpkeys[@]}\""); do
    gpg --receive-keys "$key" || echo "failed to receive $key"
  done
  for keyfile in keys/pgp/*.asc; do
    [[ -f $keyfile ]] && gpg --import "$keyfile"
  done
  true'

step "building at builddate $BUILDDATE"
# The dependencies are installed at the recorded versions already, so no -s.
nocheck=""
if [[ $NOCHECK == "1" ]]; then
  nocheck="--nocheck"
fi
as_builder "makepkg -f --noconfirm --holdver $nocheck"
rc=$?
if (( rc != 0 )); then
  fail "makepkg exit $rc" 2
fi

shopt -s nullglob
outputs=("$R$STARTDIR"/*.pkg.tar.zst)
if (( ${#outputs[@]} == 0 )); then
  fail "verifier: makepkg succeeded but left no package"
fi
if ! cp "${outputs[@]}" /job/outputs/ || ! chown -R "$OWNER" /job/outputs; then
  fail "verifier: cannot collect the packages"
fi
step built
