import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, mkdtemp, rm } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Script } from 'node:vm';
const root = fileURLToPath(new URL('../../', import.meta.url));
test('native Codex manifest registers the standalone server and matches portable metadata', async () => {
  const native = JSON.parse(await readFile(join(root, '.codex-plugin/plugin.json'), 'utf8'));
  const portable = JSON.parse(await readFile(join(root, 'plugin.json'), 'utf8'));
  assert.equal(native.mcpServers, './.mcp.json');
  assert.equal(native.skills, './skills/');
  for (const key of ['name', 'version', 'description', 'author', 'repository', 'license', 'keywords']) assert.deepEqual(native[key], portable[key], key);
  assert.deepEqual(native.interface, portable.extensions['com.openai'].interface);
  await readFile(join(root, native.interface.composerIcon));
  const legacyMcp = JSON.parse(await readFile(join(root, native.mcpServers), 'utf8'));
  const portableMcp = JSON.parse(await readFile(join(root, 'mcp.json'), 'utf8'));
  assert.deepEqual(Object.keys(legacyMcp.mcpServers), ['apple-foundation-evals']);
  const { type, ...server } = portableMcp.mcpServers['apple-foundation-evals'];
  assert.equal(type, 'stdio');
  assert.equal(server.cwd, './', 'Portable cwd must be valid against its declared schema');
  assert.deepEqual({ ...server, cwd: '.' }, legacyMcp.mcpServers['apple-foundation-evals']);
});
test('package metadata agrees with the locked dependency manifest', async () => {
  const manifest = JSON.parse(await readFile(join(root, 'package.json'), 'utf8'));
  const lock = JSON.parse(await readFile(join(root, 'package-lock.json'), 'utf8'));
  assert.equal(lock.version, manifest.version);
  assert.equal(lock.packages[''].version, manifest.version);
  assert.deepEqual(lock.packages[''].dependencies, manifest.dependencies);
  assert.deepEqual(lock.packages[''].devDependencies, manifest.devDependencies);
});
test('vendored shadcn stylesheet keeps its licensed source provenance without the CLI dependency', async () => {
  const provenance = JSON.parse(await readFile(join(root, 'ui/vendor/shadcn-provenance.json'), 'utf8'));
  const css = await readFile(join(root, 'ui/vendor/shadcn-tailwind.css'));
  assert.equal(createHash('sha256').update(css).digest('hex'), provenance.sha256);
  assert.match(await readFile(join(root, 'ui/vendor', provenance.license), 'utf8'), /MIT License/);
  const manifest = JSON.parse(await readFile(join(root, 'package.json'), 'utf8'));
  assert.equal(manifest.dependencies.shadcn, undefined);
  assert.equal(manifest.devDependencies.shadcn, undefined);
});
test('checked-in offline UI matches its current source', async () => {
  const before = await readFile(join(root, 'ui/app.html'), 'utf8');
  const built = spawnSync(process.execPath, [join(root, 'scripts/build-ui.mjs')], { encoding: 'utf8' });
  assert.equal(built.status, 0, built.stderr);
  assert.equal(await readFile(join(root, 'ui/app.html'), 'utf8'), before, 'Rebuild and include ui/app.html after changing source');
  assert.ok(!before.includes('/* STYLES */') && !before.includes('/* SCRIPT */'));
  assert.ok(!/<script[^>]+src=|<link[^>]+href=/i.test(before), 'The installed UI must not need external assets');
  const inline = before.match(/<script type="module">([\s\S]*)<\/script>/)[1];
  assert.doesNotThrow(() => new Script(inline), 'Bundling must preserve inline JavaScript syntax, including dollar-sign replacement sequences');
  assert.ok(before.includes('data-slot'), 'The package must contain its compiled component library');
});
test('generated assets use LF, empty blank lines and one final newline', async () => {
  for (const file of ['ui/app.html', 'ui/styles.css', 'ui/react/legacy.css', 'ui/vendor/THIRD-PARTY-NOTICES.txt']) {
    const content = await readFile(join(root, file), 'utf8');
    assert.doesNotMatch(content, /\r|^[ \t]+$/m, file);
    assert.equal(content, content.trimEnd() + '\n', file);
  }
});
test('distribution includes runnable manifests, native source and skills while excluding local/test data', async () => {
  const temp = await mkdtemp(join(tmpdir(), 'foundation-evals-package-test-'));
  try {
    const archive = join(temp, 'plugin.zip');
    const build = spawnSync(process.execPath, [join(root, 'scripts/package.mjs'), archive], { encoding: 'utf8' });
    assert.equal(build.status, 0, build.stderr);
    const list = spawnSync('unzip', ['-Z1', archive], { encoding: 'utf8' }); assert.equal(list.status, 0, list.stderr);
    const files = list.stdout.split('\n');
    for (const file of ['.codex-plugin/plugin.json', '.mcp.json', 'plugin.json', 'mcp.json', 'server/main.mjs', 'scripts/launch.mjs', 'samples/starter-suite.json', 'native/RunnerCore.swift', 'native/FoundationModelsRunner.swift', 'ui/app.html', 'ui/vendor/MCP-EXTENSIONS-LICENSE', 'skills/foundation-evals/SKILL.md', 'skills/evaluation-traces/SKILL.md']) assert.ok(files.includes(`apple-foundation-evals/${file}`), `Missing ${file}`);
    assert.ok(!files.some(file => /(^|\/)(tests|runs|suites|cache|node_modules)\/|WORKLOG|preview\.mjs|package\.mjs/.test(file)));
    assert.ok(!files.some(file => file.includes('../') || file.startsWith('/')));
    const manifest = JSON.parse(spawnSync('unzip', ['-p', archive, 'apple-foundation-evals/plugin.json'], { encoding: 'utf8' }).stdout);
    const mcp = JSON.parse(spawnSync('unzip', ['-p', archive, 'apple-foundation-evals/mcp.json'], { encoding: 'utf8' }).stdout);
    assert.equal(manifest.$schema, 'https://agent-plugins.org/schemas/1.0.0/plugin.schema.json');
    assert.equal(mcp.mcpServers['apple-foundation-evals'].type, 'stdio');
    const native = JSON.parse(spawnSync('unzip', ['-p', archive, 'apple-foundation-evals/.codex-plugin/plugin.json'], { encoding: 'utf8' }).stdout);
    const nativeMcp = JSON.parse(spawnSync('unzip', ['-p', archive, `apple-foundation-evals/${native.mcpServers.slice(2)}`], { encoding: 'utf8' }).stdout);
    const server = nativeMcp.mcpServers['apple-foundation-evals'];
    assert.ok(files.includes(`apple-foundation-evals/${server.args[0].slice(2)}`));
    const extracted = spawnSync('unzip', ['-q', archive, '-d', join(temp, 'installed')], { encoding: 'utf8' }); assert.equal(extracted.status, 0, extracted.stderr);
    const installed = join(temp, 'installed', 'apple-foundation-evals');
    const initialized = spawnSync(process.execPath, server.args, {
      cwd: installed, env: { ...process.env, FOUNDATION_EVALS_PLUGIN_DATA: join(temp, 'data') }, encoding: 'utf8', timeout: 10000,
      input: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'package-test', version: '1' } } }) + '\n'
        + JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'eval_open_workspace', arguments: {} } }) + '\n'
        + JSON.stringify({ jsonrpc: '2.0', id: 3, method: 'tools/list', params: {} }) + '\n'
    });
    assert.equal(initialized.status, 0, initialized.stderr);
    const responses = initialized.stdout.trim().split('\n').map(line => JSON.parse(line));
    assert.ok(responses.find(result => result.id === 1)?.result?.serverInfo);
    assert.equal(responses.find(result => result.id === 2)?.result?.structuredContent?.suites.length, 1, 'Fresh package must initialize its starter suite without a build or app');
    const workspace = responses.find(result => result.id === 3).result.tools.find(tool => tool.name === 'eval_open_workspace');
    assert.equal(workspace._meta.ui.resourceUri, 'ui://apple-foundation-evals/workspace');
    assert.deepEqual(workspace._meta['openai/ui'].entrypoints, [{ type: 'global' }, { type: 'thread' }]);
  } finally { await rm(temp, { recursive: true, force: true }); }
});
