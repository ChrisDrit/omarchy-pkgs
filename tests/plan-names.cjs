// The package directory names build-pr.yml and publish.yml plan, as their
// plan steps find them: every name a pull request or a push touches reaches
// bin/build-matrix whole, so one makepkg would refuse fails the plan instead
// of being split at a newline, trimmed or dropped on the way, and a failed
// listing or an empty dispatch fails too.
//
// Runs each plan step as the workflow writes it, up to the matrix, in a
// git fixture with bin/build-matrix and a gh stub.
const assert = require('node:assert/strict');
const { readFileSync, mkdtempSync, rmSync, writeFileSync, mkdirSync, cpSync, chmodSync, readdirSync } = require('node:fs');
const { join } = require('node:path');
const { tmpdir } = require('node:os');
const { test } = require('node:test');
const { execFileSync, spawnSync } = require('node:child_process');

// The run: | block that contains marker, dedented, cut after the line that
// makes the matrix, which is then printed.
function planUpToMatrix(workflow, marker) {
  const lines = readFileSync(`.github/workflows/${workflow}`, 'utf8').split('\n');
  for (let i = 0; i < lines.length; i++) {
    const key = lines[i].match(/^(\s*(?:-\s+)?)run:\s*\|\s*$/);
    if (!key) continue;
    const body = [];
    while (i + 1 < lines.length && (lines[i + 1].trim() === '' || lines[i + 1].search(/\S/) > key[1].length)) body.push(lines[++i]);
    const indent = Math.min(...body.filter(line => line.trim()).map(line => line.search(/\S/)));
    const script = body.map(line => line.slice(indent));
    if (!script.some(line => line.includes(marker))) continue;
    const end = script.findIndex(line => line.trim() === 'matrix=$(bin/build-matrix <<<"$names")');
    assert.ok(end > 0, `${workflow}: no matrix line in the plan`);
    return [...script.slice(0, end + 1), 'printf \'%s\\n\' "$matrix"'].join('\n');
  }
  assert.fail(`${workflow}: no plan step containing ${marker}`);
}

const git = (cwd, ...args) => execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', ...args], { cwd, encoding: 'utf8' }).trim();

const recipe = (root, name) => {
  mkdirSync(join(root, 'pkgbuilds', name, '.omarchy'), { recursive: true });
  writeFileSync(join(root, 'pkgbuilds', name, 'PKGBUILD'), 'pkgname=x\npkgver=1\npkgrel=1\narch=(any)\n');
  writeFileSync(join(root, 'pkgbuilds', name, '.omarchy', 'package.json'), '{"source": "local"}\n');
};

// A checkout with this repository's bin/build-matrix and helpers, a base
// commit with pkgbuilds/keep and pkgbuilds/gone, and a head that adds the
// given directories and deletes gone. gh lists the head's files from
// files.json, or fails when files.error exists.
function fixture(added) {
  const dir = mkdtempSync(join(tmpdir(), 'plan-names-'));
  const root = join(dir, 'root');
  mkdirSync(join(root, 'bin'), { recursive: true });
  cpSync('bin/build-matrix', join(root, 'bin/build-matrix'));
  cpSync('helpers', join(root, 'helpers'), { recursive: true });
  recipe(root, 'keep');
  recipe(root, 'gone');
  git(dir, 'init', '-q', 'root');
  git(root, 'add', '-A');
  git(root, 'commit', '-qm', 'base');
  const base = git(root, 'rev-parse', 'HEAD');
  for (const name of added) recipe(root, name);
  rmSync(join(root, 'pkgbuilds/gone'), { recursive: true });
  git(root, 'add', '-A');
  git(root, 'commit', '-qm', 'head');
  const head = git(root, 'rev-parse', 'HEAD');
  const files = git(root, 'diff', '--name-only', '-z', base, head).split('\0').filter(Boolean).map(filename => ({ filename }));
  writeFileSync(join(dir, 'files.json'), JSON.stringify(files));
  mkdirSync(join(dir, 'bin'));
  writeFileSync(join(dir, 'bin', 'gh'), `#!/bin/bash
[[ ! -e ${dir}/files.error ]] || { echo "gh: Server Error (HTTP 502)" >&2; exit 1; }
while (($#)); do [[ $1 == --jq ]] && { jq -r "$2" ${dir}/files.json; exit; }; shift; done
exit 1
`);
  chmodSync(join(dir, 'bin', 'gh'), 0o755);
  return { dir, root, base, head };
}

function plan(script, { dir, root, base, head }, env) {
  return spawnSync('bash', ['-e', '-c', script], {
    cwd: root, encoding: 'utf8',
    env: {
      ...process.env, PATH: `${join(dir, 'bin')}:${process.env.PATH}`, GITHUB_REPOSITORY: 'omacom/omarchy-pkgs',
      GITHUB_EVENT_NAME: 'pull_request', PR_NUMBER: '7', HEAD_SHA: head, BASE_SHA: base, BEFORE: base, GITHUB_SHA: head,
      DISPATCH_PACKAGES: '', ...env,
    },
  });
}

const planned = run => JSON.parse(run.stdout.trim().split('\n').pop()).include.map(entry => entry.package);

const refused = ['flea";F1_INJECTED=1;$(date)||:;:"', 'evil\nname', ' hyprland', 'trailing ', 'x$(touch pwned)'];

for (const [workflow, marker] of [['build-pr.yml', 'pulls/$PR_NUMBER/files'], ['publish.yml', 'git diff --name-only']]) {
  const script = planUpToMatrix(workflow, marker);

  test(`${workflow}: the plan builds what changed and skips a deleted package`, () => {
    const f = fixture(['good', 'libc++']);
    try {
      const run = plan(script, f);
      assert.equal(run.status, 0, run.stderr);
      assert.deepEqual(planned(run), ['good', 'libc++']);
    } finally {
      rmSync(f.dir, { recursive: true, force: true });
    }
  });

  for (const name of refused) {
    test(`${workflow}: a directory named ${JSON.stringify(name)} fails the plan`, () => {
      const f = fixture(['good', name]);
      try {
        const run = plan(script, f);
        assert.notEqual(run.status, 0, `planned: ${run.stdout}`);
        assert.match(run.stderr, /build-matrix: refusing package directory /);
        assert.ok(!readdirSync(f.root).includes('pwned'), 'a name ran a command');
      } finally {
        rmSync(f.dir, { recursive: true, force: true });
      }
    });
  }

  test(`${workflow}: a dispatch with no package fails, and one with packages plans them`, () => {
    const f = fixture(['good']);
    try {
      const empty = plan(script, f, { GITHUB_EVENT_NAME: 'workflow_dispatch', DISPATCH_PACKAGES: '  ' });
      assert.notEqual(empty.status, 0);
      assert.match(empty.stdout, /::error::Name the package directories/);
      const named = plan(script, f, { GITHUB_EVENT_NAME: 'workflow_dispatch', DISPATCH_PACKAGES: ' keep  good ' });
      assert.equal(named.status, 0, named.stderr);
      assert.deepEqual(planned(named), ['keep', 'good']);
    } finally {
      rmSync(f.dir, { recursive: true, force: true });
    }
  });
}

test('build-pr.yml: a pull request whose files cannot be listed fails the plan', () => {
  const f = fixture(['good']);
  try {
    writeFileSync(join(f.dir, 'files.error'), '');
    const run = plan(planUpToMatrix('build-pr.yml', 'pulls/$PR_NUMBER/files'), f);
    assert.notEqual(run.status, 0, `planned: ${run.stdout}`);
  } finally {
    rmSync(f.dir, { recursive: true, force: true });
  }
});
