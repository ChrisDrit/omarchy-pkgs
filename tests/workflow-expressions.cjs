// Values reach a workflow's scripts through env, never pasted into them. The
// runner substitutes ${{ }} into the script text before the shell reads it,
// so a package directory named x$(cmd), a dispatch input or a pull request
// field pasted there runs as code: on the builder host, for build-pr.yml's
// matrix.package. Read through env, the same value is only a string.
//
// Every workflow: no event, input, matrix or job/step output value inside a
// run: or script: block. build-pr.yml, which runs for pull requests: no
// ${{ }} inside one at all.
const assert = require('node:assert/strict');
const { readFileSync, readdirSync } = require('node:fs');
const { test } = require('node:test');

const dir = '.github/workflows';

// Every ${{ }} inside a run: or script: value, with the line it starts on.
// A value runs on to the last line indented deeper than its key: a block
// scalar (| or >) or a plain scalar continued on the next lines. An
// expression may span lines.
function scriptValues(text) {
  const lines = text.split('\n');
  const values = [];
  const outside = [];
  for (let i = 0; i < lines.length; i++) {
    const key = lines[i].match(/^(\s*(?:-\s+)?)(run|script):(.*)$/);
    if (!key) {
      outside.push(lines[i]);
      continue;
    }
    const column = key[1].length;
    const first = i;
    const body = [key[3]];
    while (i + 1 < lines.length && (lines[i + 1].trim() === '' || lines[i + 1].search(/\S/) > column)) body.push(lines[++i]);
    values.push({ first, value: body.join('\n') });
  }
  return { values, outside: outside.join('\n') };
}

function scriptExpressions(text) {
  const found = [];
  for (const { first, value } of scriptValues(text).values) {
    for (const match of value.matchAll(/\$\{\{([\s\S]*?)\}\}/g)) {
      found.push({ line: first + 1 + value.slice(0, match.index).split('\n').length - 1, expr: match[1].trim().replace(/\s+/g, ' ') });
    }
  }
  return found;
}

// A value whose text comes from outside the workflow: the event (a branch
// name, a title, a pull request's fields), a dispatch or call input, a
// matrix entry, or another job's or step's output, in dot or index syntax
// (github.event_name is not one).
const data = /\b(event|head_ref|inputs|matrix|outputs)\b/;

// What the scanner cannot read: a quoted run or script key, or a line that
// opens a flow mapping ({ ... }) and has a run or script key. No workflow
// may use them outside its scripts.
const unreadable = /^\s*(?:-\s+)?["'](run|script)["']\s*:|^(?=.*(?:^\s*-\s*\{|:\s*\{(?!\s*\})))(?=.*\b(run|script)["']?\s*:)/m;

const workflows = readdirSync(dir).filter(name => /\.ya?ml$/.test(name)).sort();

test('the scanner finds expressions in run: and script: blocks, and only there', () => {
  const sample = [
    'jobs:',
    '  a:',
    '    name: ${{ matrix.package }}',
    '    steps:',
    '      - run: echo "${{ matrix.package }}"',
    '      - name: block',
    '        env:',
    '          SAFE: ${{ matrix.package }}',
    '        run: |',
    '          echo one',
    '',
    '          echo "${{ github.event.pull_request.title }}"',
    '      - uses: actions/github-script@v7',
    '        with:',
    '          script: >-',
    '            core.info("${{ inputs.packages }}")',
    '      - run: echo "$SAFE ${{ github.sha }}"',
  ].join('\n');
  assert.deepEqual(scriptExpressions(sample), [
    { line: 5, expr: 'matrix.package' },
    { line: 12, expr: 'github.event.pull_request.title' },
    { line: 16, expr: 'inputs.packages' },
    { line: 17, expr: 'github.sha' },
  ]);
  // Spread over lines, in a plain scalar continued on the next line, or in
  // index syntax.
  const spread = [
    '      - run: |',
    '          echo "${{',
    '            matrix.package }}"',
    '      - run: echo one',
    '          "${{ github[\'event\'][\'inputs\'][\'packages\'] }}"',
    '      - run: echo "${{ matrix[\'package\'] }}" "${{ github.event_name }}"',
  ].join('\n');
  const exprs = scriptExpressions(spread);
  assert.deepEqual(exprs.map(({ line, expr }) => [line, expr]), [
    [2, 'matrix.package'],
    [5, "github['event']['inputs']['packages']"],
    [6, "matrix['package']"],
    [6, 'github.event_name'],
  ]);
  assert.deepEqual(exprs.map(({ expr }) => data.test(expr)), [true, true, true, false]);
  for (const bad of [
    '      - "run": echo', "      - 'script': x", "      - {run: 'echo'}", '        with: { script: x }',
    `      - { "run": 'echo "\${{ github.event.pull_request.title }}"' }`, "      - { 'run': echo }", '        with: { "script": x }',
    `      - { name: '\${{ matrix.package }}', run: 'echo "\${{ github.event.pull_request.title }}"' }`,
    `        with: { name: '\${{ matrix.package }}', script: 'core.info("\${{ inputs.packages }}")' }`,
  ]) assert.match(scriptValues(bad).outside, unreadable, bad);
  for (const good of ['    permissions: {}', '    name: build (${{ matrix.package }}, ${{ matrix.arch }})', '          name: ${{ matrix.package }}-run']) {
    assert.doesNotMatch(scriptValues(good).outside, unreadable, good);
  }
  assert.doesNotMatch(scriptValues("      - run: jq -n '{run: $run}'").outside, unreadable);
  assert.ok(workflows.includes('build-pr.yml') && workflows.includes('publish.yml'));
});

test('every workflow writes its scripts in a form the scanner reads', () => {
  const unread = workflows.filter(name => unreadable.test(scriptValues(readFileSync(`${dir}/${name}`, 'utf8')).outside));
  assert.deepEqual(unread, []);
});

test('no workflow pastes an event, input, matrix or output value into a script', () => {
  const pasted = [];
  for (const name of workflows) {
    for (const { line, expr } of scriptExpressions(readFileSync(`${dir}/${name}`, 'utf8'))) {
      if (data.test(expr)) pasted.push(`${dir}/${name}:${line}: \${{ ${expr} }}`);
    }
  }
  assert.deepEqual(pasted, [], `pass these through env:\n${pasted.join('\n')}`);
});

test('build-pr.yml, which pull requests run, pastes no value into a script', () => {
  const pasted = scriptExpressions(readFileSync(`${dir}/build-pr.yml`, 'utf8'))
    .map(({ line, expr }) => `${dir}/build-pr.yml:${line}: \${{ ${expr} }}`);
  assert.deepEqual(pasted, [], `pass these through env:\n${pasted.join('\n')}`);
});
