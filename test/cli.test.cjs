const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { cpSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join, resolve } = require('node:path');
const { test } = require('node:test');

const repository = resolve(__dirname, '..');
const example = (name) => join(repository, 'examples', name);

function run(...args) {
  const result = spawnSync('moon', ['run', 'cmd', '--target', 'js', '--', ...args], {
    cwd: repository,
    encoding: 'utf8',
    timeout: 60_000,
  });
  if (result.error) throw result.error;
  assert.equal(result.signal, null);
  return result;
}

function findings(result) {
  return JSON.parse(result.stdout).findings.map(({ code, file, location, line, column }) => [
    code,
    line ? `${file}:${line}:${column}` : location ? `${file} ${location}` : file,
  ]);
}

function temporaryProject(t) {
  const root = mkdtempSync(join(tmpdir(), 'routecheck project '));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return root;
}

function writeProject(root, files) {
  for (const [path, content] of Object.entries(files)) {
    mkdirSync(join(root, path, '..'), { recursive: true });
    writeFileSync(join(root, path), content);
  }
}

test('manifest diagnostics and exit status for the small examples', () => {
  const clean = run(example('good'));
  assert.equal(clean.status, 0, clean.stderr);
  assert.deepEqual(findings(clean), []);

  const broken = run(example('broken'));
  assert.equal(broken.status, 1, broken.stderr);
  assert.deepEqual(findings(broken), [
    ['invalid-route', 'app.json $.pages[2]'],
    ['missing-page-file', 'app.json $.pages[1]'],
    ['tab-route-not-in-main-package', 'app.json $.tabBar.list[1].pagePath'],
  ]);
});

test('the realistic shop is clean and reports per-package sizes', () => {
  const audit = run(example('shop'));
  assert.equal(audit.status, 0, audit.stderr);
  const report = JSON.parse(audit.stdout);
  assert.deepEqual(report.findings, []);
  assert.deepEqual(
    report.packages.map(({ name, root, independent }) => [name, root, independent]),
    [
      ['__APP__', '', false],
      ['goods', 'packageGoods', false],
      ['order', 'packageOrder', false],
      ['activity', 'packageActivity', true],
    ],
  );
  // app.js/app.wxss imports, 6 tab icons, sitemap, a global component, page
  // components, a WXML import, a template image, a WXS module and requires.
  assert.equal(report.summary.edges, 19);
});

test('every injected defect in the broken shop is found at its source position', () => {
  const audit = run(example('shop-broken'));
  assert.equal(audit.status, 1, audit.stderr);
  assert.deepEqual(findings(audit), [
    ['wxml-syntax-error', 'pages/me/index.wxml:1:1'],
    ['local-wxss-resource', 'packageGoods/detail/index.wxss:2:27'],
    ['unknown-template', 'pages/index/index.wxml:3:3'],
    ['unused-component', 'pages/index/index.json $.usingComponents["coupon"]'],
    ['cross-subpackage-reference', 'packageOrder/confirm/index.json $.usingComponents["thumb"]'],
    ['main-package-references-subpackage', 'pages/cart/index.js:1:26'],
    ['independent-subpackage-dependency', 'packageActivity/landing/index.js:1:29'],
    ['navigate-to-tab-page', 'pages/me/index.js:3:26'],
    ['switch-tab-to-non-tab-page', 'pages/me/index.js:6:25'],
    ['unknown-navigation-target', 'components/goods-card/index.js:5:28'],
    ['require-cycle', 'utils/cache.js:1:23'],
    ['unreferenced-file', 'utils/legacy-share.js'],
    ['move-to-subpackage', 'utils/chart.js'],
  ]);
  const summary = JSON.parse(audit.stdout).summary;
  assert.deepEqual([summary.errors, summary.warnings, summary.infos], [8, 3, 2]);
});

test('SARIF output is valid 2.1.0 with one result per finding', () => {
  const audit = run('--format', 'sarif', example('shop-broken'));
  assert.equal(audit.status, 1, audit.stderr);
  const sarif = JSON.parse(audit.stdout);
  assert.equal(sarif.version, '2.1.0');
  const [runResult] = sarif.runs;
  assert.equal(runResult.results.length, 13);
  const levels = new Set(runResult.results.map((r) => r.level));
  assert.deepEqual([...levels].sort(), ['error', 'note', 'warning']);
  const first = runResult.results[0];
  assert.equal(runResult.tool.driver.rules[first.ruleIndex].id, first.ruleId);
  assert.deepEqual(first.locations[0].physicalLocation.region, { startLine: 1, startColumn: 1 });
});

test('DOT output clusters packages and marks violating edges', () => {
  const audit = run('--format', 'dot', example('shop-broken'));
  assert.equal(audit.status, 1, audit.stderr);
  assert.match(audit.stdout, /^digraph miniapp \{/);
  assert.match(audit.stdout, /subgraph cluster_3 \{\n    label="activity";/);
  assert.match(audit.stdout, /"pages\/cart\/index\.js" -> "packageGoods\/utils\/sku\.js" \[label="require", color=red/);
  assert.match(audit.stdout, /"packageOrder\/confirm\/index\.js" -> "packageGoods\/utils\/sku\.js" \[label="require\.async", style=dashed\]/);
});

test('--strict fails on warnings and size limits are configurable', (t) => {
  const root = temporaryProject(t);
  writeProject(root, {
    'app.json': '{"pages":["pages/a/index"]}',
    'app.js': 'App({})',
    'pages/a/index.js': 'Page({})',
    'pages/a/index.wxml': '<view />',
    'pages/a/index.wxss': '.a { background: url(./bg.png) }',
  });
  assert.equal(run(root).status, 0);
  assert.equal(run('--strict', root).status, 1);

  const limited = run('--max-package-kb=1', '--max-total-kb', '1', example('shop'));
  assert.equal(limited.status, 1, limited.stderr);
  assert.deepEqual(
    findings(limited).map(([code]) => code),
    ['package-size-exceeded', 'total-size-exceeded'],
  );
  const bad = run('--max-package-kb', 'lots', example('shop'));
  assert.equal(bad.status, 2);
  assert.match(bad.stderr, /--max-package-kb expects a positive number/);
});

test('a project directory can select a nested mini program with UTF-8 BOM files', (t) => {
  const root = temporaryProject(t);
  const nestedSource = join(root, 'output', 'mini app');
  mkdirSync(join(root, 'output'));
  cpSync(example('good'), nestedSource, { recursive: true });
  writeFileSync(join(root, 'project.config.json'), '﻿{"miniprogramRoot":"output/mini app"}');
  writeFileSync(join(nestedSource, 'app.json'), '﻿{"pages":["pages/home/index"]}');

  const audit = run(root);
  assert.equal(audit.status, 0, audit.stderr);
  // The other example pages are now unreferenced but still packaged.
  assert.deepEqual(
    findings(audit).map(([code]) => code).filter((code) => code !== 'unreferenced-file'),
    [],
  );
});

test('compiler plugins in project.config.json let TypeScript pages stand in for JavaScript', (t) => {
  const root = temporaryProject(t);
  writeProject(root, {
    'project.config.json': JSON.stringify({
      miniprogramRoot: 'miniprogram/',
      setting: { useCompilerPlugins: ['typescript', { type: 'less' }] },
    }),
    'miniprogram/app.json': '{"pages":["pages/a/index"]}',
    'miniprogram/app.ts': "import type { Config } from './types'\nApp({})",
    'miniprogram/app.less': "// theme\n@import './vars.less';",
    'miniprogram/vars.less': '@c: red;',
    'miniprogram/pages/a/index.ts': "import { go } from '../../utils/missing'\nPage({ go })",
    'miniprogram/pages/a/index.wxml': '<view />',
  });
  const audit = run(root);
  assert.equal(audit.status, 1, audit.stderr);
  assert.deepEqual(findings(audit), [['unresolved-module', 'pages/a/index.ts:1:20']]);

  // Without the plugin setting the TypeScript page has no compiled script.
  writeFileSync(join(root, 'project.config.json'), '{"miniprogramRoot":"miniprogram/"}');
  const plain = run(root);
  assert.ok(findings(plain).some(([code]) => code === 'missing-page-file'));
});

test('a configured source directory cannot escape the project root', (t) => {
  const root = temporaryProject(t);
  const project = join(root, 'project');
  mkdirSync(project);
  cpSync(example('good'), join(root, 'outside'), { recursive: true });
  writeFileSync(join(project, 'project.config.json'), '{"miniprogramRoot":"../outside"}');

  const audit = run(project);
  assert.equal(audit.status, 2);
  assert.equal(audit.stdout, '');
  assert.match(audit.stderr, /miniprogramRoot.*(?:within|relative)/);
});

test('invalid UTF-8 in app.json is a filesystem error; in a page it is a finding', (t) => {
  const root = temporaryProject(t);
  writeFileSync(join(root, 'app.json'), Buffer.from([0x7b, 0xff, 0x7d]));
  const audit = run(root);
  assert.equal(audit.status, 2);
  assert.equal(audit.stdout, '');
  assert.match(audit.stderr, /UTF-8/i);

  const other = temporaryProject(t);
  writeProject(other, {
    'app.json': '{"pages":["pages/a/index"]}',
    'pages/a/index.js': Buffer.from([0x50, 0xff]),
    'pages/a/index.wxml': '<view />',
  });
  const page = run(other);
  assert.equal(page.status, 1);
  assert.deepEqual(findings(page), [['unreadable-file', 'pages/a/index.js']]);
});

test('the text format reports the same findings with a human-readable location', () => {
  const audit = run('--format', 'text', example('shop-broken'));
  assert.equal(audit.status, 1, audit.stderr);
  assert.match(audit.stdout, /^error   pages\/me\/index\.wxml:1:1  \[wxml-syntax-error\]/m);
  assert.match(audit.stdout, /goods +0\.\d KiB +of 2048\.0 KiB +10 files +\(0\.1 KiB movable from main\)/);
  assert.match(audit.stdout, /8 errors, 3 warnings, 2 notes\./);
});

test('help succeeds and an unknown option is an invocation error', () => {
  const help = run('--help');
  assert.equal(help.status, 0, help.stderr);
  assert.match(help.stdout, /--format json\|text\|sarif\|dot/);

  const badOption = run('--unknown-option', example('good'));
  assert.equal(badOption.status, 2);
  assert.equal(badOption.stdout, '');
  assert.match(badOption.stderr, /--unknown-option/);
});
