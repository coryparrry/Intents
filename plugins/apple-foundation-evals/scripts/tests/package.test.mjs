import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, mkdtemp, rm, lstat } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { Script } from 'node:vm';
const root = fileURLToPath(new URL('../../', import.meta.url));

test('checked-in offline UI matches its current source', async () => {
  const before = await readFile(join(root, 'ui/app.html'), 'utf8');
  const built = spawnSync(process.execPath, [join(root, 'scripts/build-ui.mjs')], { encoding: 'utf8' });
  assert.equal(built.status, 0, built.stderr);
  assert.equal(await readFile(join(root, 'ui/app.html'), 'utf8'), before, 'Rebuild and include ui/app.html after changing source');
  assert.ok(!before.includes('/* STYLES */') && !before.includes('/* SCRIPT */'));
  assert.ok(!/<script[^>]+src=|<link[^>]+href=/i.test(before), 'The installed UI must not need external assets');
  const inline = before.match(/<script type="module">([\s\S]*)<\/script>/)[1];
  assert.doesNotThrow(() => new Script(inline), 'Bundling must preserve inline JavaScript syntax, including dollar-sign replacement sequences');
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
    // The repository map is test input only; installed plugins contain all native sources locally.
    const shared = JSON.parse(await readFile(join(root, '../../script/shared_app_sources.json'), 'utf8'));
    const sharedNativePaths = Object.keys(shared).map(canonical => {
      assert.ok(canonical.startsWith('plugins/apple-foundation-evals/native/AppEngine/'));
      return canonical.slice('plugins/apple-foundation-evals/'.length);
    });
    assert.equal(sharedNativePaths.length, 24);
    for (const path of sharedNativePaths) assert.equal(files.filter(file => file === `apple-foundation-evals/${path}`).length, 1, `Missing or repeated shared source ${path}`);
    assert.ok(!files.includes('apple-foundation-evals/native/AppEngine/EvaluationCaseImporter.swift'));
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
    for (const path of sharedNativePaths) {
      const installedPath = join(installed, path);
      const stat = await lstat(installedPath);
      assert.ok(stat.isFile() && !stat.isSymbolicLink(), `Shared source must be a regular installed file: ${path}`);
      assert.deepEqual(await readFile(installedPath), await readFile(join(root, path)), `Installed shared source differs: ${path}`);
    }
    // Loading the extracted launcher discovers its native source closure without repository access or compilation.
    const installedLauncher = await import(pathToFileURL(join(installed, 'scripts/launch.mjs')).href);
    assert.equal(typeof installedLauncher.nativeBinary, 'function');
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
