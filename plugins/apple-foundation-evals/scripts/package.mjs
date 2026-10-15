import { spawnSync } from 'node:child_process';
import { mkdtemp, cp, mkdir, readFile, rename, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../', import.meta.url));
const manifest = JSON.parse(await readFile(resolve(root, 'plugin.json'), 'utf8'));
const output = resolve(process.argv[2] || resolve(root, '../..', 'dist', `${manifest.name}-${manifest.version}.zip`));
const temp = await mkdtemp(resolve(tmpdir(), 'foundation-evals-package-'));
try {
  const staged = resolve(temp, manifest.name); await mkdir(staged);
  // An allowlist keeps test fixtures, cached binaries and private local data out.
  for (const entry of ['.codex-plugin/plugin.json', '.mcp.json', 'plugin.json', 'mcp.json', 'package.json', 'LICENSE', 'README.md', 'assets', 'server', 'scripts/launch.mjs', 'samples/starter-suite.json', 'skills', 'ui/app.html', 'ui/vendor/THIRD-PARTY-NOTICES.txt', 'ui/vendor/MCP-EXTENSIONS-LICENSE', 'ui/vendor/README.md', 'native/RunnerCore.swift', 'native/FoundationModelsRunner.swift', 'native/README.md', 'native/AppEngine']) {
    const destination = resolve(staged, entry); await mkdir(dirname(destination), { recursive: true }); await cp(resolve(root, entry), destination, { recursive: true });
  }
  await mkdir(dirname(output), { recursive: true });
  const archive = resolve(temp, 'plugin.zip');
  const result = spawnSync('zip', ['-qr', archive, manifest.name], { cwd: temp, encoding: 'utf8' });
  if (result.status !== 0) throw Error(result.stderr || 'ZIP creation failed');
  await rename(archive, output);
  console.error(`Packaged ${manifest.name} ${manifest.version}: ${output}`);
} finally { await rm(temp, { recursive: true, force: true }); }
