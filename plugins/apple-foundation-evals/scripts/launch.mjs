import { runBuildCommand } from '../server/native-build-process.mjs';
import { createHash, randomUUID } from 'node:crypto';
import { access, lstat, mkdir, readFile, readdir, rename, unlink } from 'node:fs/promises';
import { constants } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { homedir } from 'node:os';

const pluginRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const compiling = new Map();
const engineSources = (await readdir(join(pluginRoot, 'native/AppEngine'))).filter((name) => name.endsWith('.swift')).sort();
const sources = ['RunnerCore.swift', 'FoundationModelsRunner.swift', ...engineSources.map((name) => `AppEngine/${name}`)].map((name) => join(pluginRoot, 'native', name));

async function executable(path) {
  const stat = await lstat(path);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('Native binary must be a regular file');
  await access(path, constants.X_OK);
  return path;
}
async function compile(target, cache, signal) {
  const lock = `${target}.building`;
  let acquired = false;
  for (let attempt = 0; attempt < 180; attempt++) {
    if (signal?.aborted) throw new Error('Native build cancelled');
    try { return await executable(target); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    try { await mkdir(lock, { mode: 0o700 }); acquired = true; break; }
    catch (error) {
      if (error.code !== 'EEXIST') throw error;
      const stat = await lstat(lock);
      if (stat.isSymbolicLink() || !stat.isDirectory()) throw new Error('Invalid native build lock');
      if (Date.now() - stat.mtimeMs > 5 * 60 * 1000) throw new Error('Native build lock is stale; remove it and retry');
      await new Promise((accept) => setTimeout(accept, 1000));
    }
  }
  if (!acquired) throw new Error('Timed out waiting for native compiler');
  const temporary = join(cache, `native-${randomUUID()}`);
  try {
    const architecture = process.arch === 'arm64' ? 'arm64' : 'x86_64';
    await runBuildCommand('/usr/bin/xcrun', ['swiftc', '-O', '-parse-as-library', '-target', `${architecture}-apple-macos26.0`, ...sources, '-o', temporary], { signal });
    await executable(temporary);
    await rename(temporary, target);
    return target;
  } finally {
    await unlink(temporary).catch(() => {});
    const { rmdir } = await import('node:fs/promises');
    await rmdir(lock).catch(() => {});
  }
}

/** Resolve or compile the runner lazily. The installed plugin source is never modified. */
export async function nativeBinary({ dataDir, env = process.env, signal } = {}) {
  if (env.FOUNDATION_EVALS_NATIVE_BINARY) return executable(resolve(env.FOUNDATION_EVALS_NATIVE_BINARY));
  if (process.platform !== 'darwin') throw new Error('Apple Foundation Models requires macOS 26 or newer');
  const bundled = join(pluginRoot, 'build/native/foundation-evals-native');
  try { return await executable(bundled); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const contents = await Promise.all(sources.map((source) => readFile(source)));
  const hasher = createHash('sha256').update(`app-engine-v1:${process.arch}:macos26-with-macos27-engine`);
  for (let index = 0; index < sources.length; index++) hasher.update(sources[index].slice(pluginRoot.length)).update(contents[index]);
  const hash = hasher.digest('hex').slice(0, 24);
  const cache = join(resolve(dataDir || env.FOUNDATION_EVALS_PLUGIN_DATA || env.PLUGIN_DATA || join(homedir(), '.local/share/apple-foundation-evals')), 'native-cache');
  await mkdir(cache, { recursive: true, mode: 0o700 });
  if ((await lstat(cache)).isSymbolicLink()) throw new Error('Native cache must not be a symlink');
  const target = join(cache, `foundation-evals-${hash}`);
  if (!compiling.has(target)) compiling.set(target, compile(target, cache, signal).finally(() => compiling.delete(target)));
  return compiling.get(target);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) await import('../server/main.mjs');
