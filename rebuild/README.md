# Rebuilding published packages

`omarchy-repro` checks that a package on pkgs.omarchy.org is what its recipe builds. It is the verification Arch's rebuilderd does with `archlinux-repro`, for packages built the way this repository builds them:

1. Read the package's `.BUILDINFO` and validate every field it will use.
2. Find the recipe: the commit whose `pkgbuilds/<name>/PKGBUILD` hashes to `pkgbuild_sha256sum`.
3. Fetch every `installed` package at its exact version: our names from our channels, the rest from archive.archlinux.org.
4. In one unprivileged container (`inner.sh`), create the root from exactly those packages, apply what `build/Dockerfile` does to the builder image, and run makepkg as `builder` the way `build/build.sh` does, with the recorded `builddate` as `SOURCE_DATE_EPOCH`.
5. Compare the rebuilt packages with the published ones byte for byte, or leave them in `--outdir` for rebuilderd's worker to compare.

Any difference between `inner.sh` and `build/Dockerfile` or `build/build.sh` shows up as a package that doesn't reproduce, so a change to one needs the same change to the other.

```sh
# compare one build's published files with their rebuild
rebuild/omarchy-repro walker-2.17.2-1-x86_64.pkg.tar.zst walker-debug-2.17.2-1-x86_64.pkg.tar.zst

# rebuild and leave the packages in a directory (rebuilderd's backend does this)
rebuild/omarchy-repro --nocheck --outdir out/ -- walker-2.17.2-1-x86_64.pkg.tar.zst
```

The last line is always `omarchy-repro: <pkgbase> <version> <status> <seconds> <detail>`, with the status one of GOOD, BAD, BUILT, FTBFS, NOINPUT, NORECIPE, INVALID or VERIFIER (the meanings are at the top of `omarchy-repro`). VERIFIER and INVALID say nothing about the package.

Files:

- `omarchy-repro`: the verifier.
- `inner.sh`: what runs in the container.
- `rebuilder-omarchy.sh`: rebuilderd's backend; `/etc/rebuilderd-worker.conf` points `[backend."archlinux"] path` at it.
- `cleanup`: removes what a killed job left (`--all` before the worker starts, `--older-than` from a timer).

`tests/rebuild-verifier.sh` covers validation, the recipe lookup, inputs and the verdicts without Docker or network.
