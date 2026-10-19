// build-pr.yml lays a pull request's package directories over the base
// branch's tooling, in the plan and in each build. The artifact a build
// uploads is named for the git tree of pkgbuilds/<package> at the pull
// request's head, and publish.yml signs it as that tree, so the directories
// the build reads must be exactly that tree: a file the pull request deleted
// (a patch, an install hook, a test) must not stay behind from base.
//
// Runs both overlay steps, as written in the workflow, on a checkout of a
// base commit against a head that deletes, changes and adds files.
const assert = require('node:assert/strict');
const { readFileSync, mkdtempSync, rmSync, writeFileSync, existsSync } = require('node:fs');
const { join } = require('node:path');
const { tmpdir } = require('node:os');
const { test } = require('node:test');
const { execFileSync, spawnSync } = require('node:child_process');

// Every run: | block of the workflow, dedented.
function runBlocks(text) {
  const lines = text.split('\n');
  const blocks = [];
  for (let i = 0; i < lines.length; i++) {
    const key = lines[i].match(/^(\s*(?:-\s+)?)run:\s*\|\s*$/);
    if (!key) continue;
    const body = [];
    while (i + 1 < lines.length && (lines[i + 1].trim() === '' || lines[i + 1].search(/\S/) > key[1].length)) body.push(lines[++i]);
    const indent = Math.min(...body.filter(line => line.trim()).map(line => line.search(/\S/)));
    blocks.push(body.map(line => line.slice(indent)).join('\n'));
  }
  return blocks;
}

const overlays = runBlocks(readFileSync('.github/workflows/build-pr.yml', 'utf8'))
  .filter(script => /git fetch --no-tags --depth=1 origin "\$HEAD_SHA"/.test(script) && / -- pkgbuilds\/$/m.test(script));

const sh = (cwd, ...args) => execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', ...args], { cwd, encoding: 'utf8' }).trim();

// origin: master with foo (PKGBUILD, fix.patch, foo.install); pr deletes
// fix.patch, changes PKGBUILD and adds bar. runner: the base checkout,
// shallow as actions/checkout makes it.
function fixture() {
  const dir = mkdtempSync(join(tmpdir(), 'overlay-'));
  const work = join(dir, 'work');
  sh(dir, 'init', '-q', '--bare', 'origin.git');
  sh(dir, 'init', '-q', '-b', 'master', 'work');
  execFileSync('bash', ['-c', `
    set -e
    mkdir -p pkgbuilds/foo bin
    echo 'pkgname=foo' >pkgbuilds/foo/PKGBUILD
    echo patch >pkgbuilds/foo/fix.patch
    echo hook >pkgbuilds/foo/foo.install
    printf '#!/bin/bash\\n' >bin/build-matrix
    chmod +x bin/build-matrix`], { cwd: work });
  sh(work, 'add', '-A');
  sh(work, 'commit', '-qm', 'base');
  sh(work, 'checkout', '-qb', 'pr');
  sh(work, 'rm', '-q', 'pkgbuilds/foo/fix.patch');
  writeFileSync(join(work, 'pkgbuilds/foo/PKGBUILD'), 'pkgname=foo\npkgrel=2\n');
  execFileSync('bash', ['-c', 'mkdir -p pkgbuilds/bar && echo pkgname=bar >pkgbuilds/bar/PKGBUILD'], { cwd: work });
  sh(work, 'add', '-A');
  sh(work, 'commit', '-qm', 'head');
  const head = sh(work, 'rev-parse', 'HEAD');
  sh(work, 'push', '-q', join(dir, 'origin.git'), 'master', 'pr');
  sh(dir, 'clone', '-q', '--depth=1', '-b', 'master', `file://${join(dir, 'origin.git')}`, 'runner');
  return { dir, runner: join(dir, 'runner'), head };
}

test('build-pr.yml has an overlay step in the plan and in the build', () => {
  assert.equal(overlays.length, 2, 'expected the changes job\'s and the build job\'s overlay');
});

const overlay = (index, runner, dir, head) => spawnSync('bash', ['-e', '-c', overlays[index]], {
  cwd: runner, encoding: 'utf8', env: { ...process.env, HEAD_SHA: head, GITHUB_OUTPUT: join(dir, 'out') },
});

for (const [index, which] of ['plan', 'build'].entries()) {
  test(`the ${which}'s overlay leaves exactly the head's package tree`, () => {
    const { dir, runner, head } = fixture();
    try {
      assert.equal(sh(runner, 'rev-parse', '--is-shallow-repository'), 'true');
      const run = overlay(index, runner, dir, head);
      assert.equal(run.status, 0, run.stderr);
      assert.ok(!existsSync(join(runner, 'pkgbuilds/foo/fix.patch')), 'a file the head deleted stayed from base');
      assert.ok(existsSync(join(runner, 'pkgbuilds/bar/PKGBUILD')), 'a file the head added is missing');
      assert.equal(readFileSync(join(runner, 'pkgbuilds/foo/PKGBUILD'), 'utf8'), 'pkgname=foo\npkgrel=2\n');
      const diff = spawnSync('git', ['diff', '--quiet', head, '--', 'pkgbuilds/'], { cwd: runner });
      assert.equal(diff.status, 0, 'pkgbuilds/ differs from the head');
      assert.equal(sh(runner, 'ls-files', '--others', '--', 'pkgbuilds/'), '');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
}

test('the build stops when pkgbuilds/ still differs from the head after the overlay', () => {
  const { dir, runner, head } = fixture();
  try {
    writeFileSync(join(runner, 'pkgbuilds/foo/stray.patch'), 'left over\n');
    const run = overlay(1, runner, dir, head);
    assert.notEqual(run.status, 0);
    assert.match(run.stdout, /::error::pkgbuilds\/ is not the tree of [0-9a-f]{40}/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
