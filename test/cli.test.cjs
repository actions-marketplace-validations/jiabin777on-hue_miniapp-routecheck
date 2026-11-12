const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { cpSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join, resolve } = require('node:path');
const { test } = require('node:test');

const repository = resolve(__dirname, '..');
const cleanExample = join(repository, 'examples', 'good');
const brokenExample = join(repository, 'examples', 'broken');

function run(...args) {
  const result = spawnSync('moon', ['run', 'cmd', '--target', 'js', '--', ...args], {
    cwd: repository,
    encoding: 'utf8',
    timeout: 30_000,
  });
  if (result.error) throw result.error;
  assert.equal(result.signal, null);
  return result;
}

function temporaryProject(t) {
  const root = mkdtempSync(join(tmpdir(), 'routecheck project '));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return root;
}

test('JSON output and exit status distinguish clean and broken mini programs', () => {
  const clean = run(cleanExample);
  assert.equal(clean.status, 0, clean.stderr);
  assert.deepEqual(JSON.parse(clean.stdout), []);

  const broken = run(brokenExample);
  assert.equal(broken.status, 1, broken.stderr);
  const diagnostics = JSON.parse(broken.stdout);
  assert.deepEqual(diagnostics.map(({ code, location }) => [code, location]), [
    ['invalid-route', '$.pages[2]'],
    ['missing-page-file', '$.pages[1]'],
    ['tab-route-not-in-main-package', '$.tabBar.list[1].pagePath'],
  ]);
});

test('a project directory can select a nested mini program with UTF-8 BOM files', (t) => {
  const root = temporaryProject(t);
  const nestedSource = join(root, 'output', 'mini app');
  mkdirSync(join(root, 'output'));
  cpSync(cleanExample, nestedSource, { recursive: true });
  writeFileSync(join(root, 'project.config.json'), '\uFEFF{"miniprogramRoot":"output/mini app"}');
  writeFileSync(join(nestedSource, 'app.json'), '\uFEFF{"pages":["pages/home/index"]}');

  const audit = run(root);
  assert.equal(audit.status, 0, audit.stderr);
  assert.deepEqual(JSON.parse(audit.stdout), []);
});

test('a configured source directory cannot escape the project root', (t) => {
  const root = temporaryProject(t);
  const project = join(root, 'project');
  mkdirSync(project);
  cpSync(cleanExample, join(root, 'outside'), { recursive: true });
  writeFileSync(join(project, 'project.config.json'), '{"miniprogramRoot":"../outside"}');

  const audit = run(project);
  assert.equal(audit.status, 2);
  assert.equal(audit.stdout, '');
  assert.match(audit.stderr, /miniprogramRoot.*(?:within|relative)/);
});

test('invalid UTF-8 fails with a filesystem error before the manifest is parsed', (t) => {
  const root = temporaryProject(t);
  writeFileSync(join(root, 'app.json'), Buffer.from([0x7b, 0xff, 0x7d]));

  const audit = run(root);
  assert.equal(audit.status, 2);
  assert.equal(audit.stdout, '');
  assert.match(audit.stderr, /UTF-8/i);
});

test('the text format reports the same findings with a human-readable location', () => {
  const audit = run('--format', 'text', brokenExample);
  assert.equal(audit.status, 1, audit.stderr);
  assert.match(audit.stdout, /\[invalid-route\] \$\.pages\[2\]/);
  assert.match(audit.stdout, /\[missing-page-file\] \$\.pages\[1\].*pages\/missing\/index\.js/);
});

test('help succeeds and an unknown option is an invocation error', () => {
  const help = run('--help');
  assert.equal(help.status, 0, help.stderr);
  assert.match(help.stdout, /--format/);

  const badOption = run('--unknown-option', cleanExample);
  assert.equal(badOption.status, 2);
  assert.equal(badOption.stdout, '');
  assert.match(badOption.stderr, /--unknown-option/);
});
