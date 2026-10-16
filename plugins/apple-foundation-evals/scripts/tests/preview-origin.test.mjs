import assert from 'node:assert/strict';
import { test } from 'node:test';
import { spawn } from 'node:child_process';
import { request } from 'node:http';
import { mkdtemp, readdir, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

test('preview accepts same-origin JSON and rejects foreign mutations before persistence', { timeout: 20000 }, async () => {
  const data = await mkdtemp(join(tmpdir(), 'eval-preview-origin-'));
  const child = spawn(process.execPath, [fileURLToPath(new URL('../preview.mjs', import.meta.url))], {
    env: { ...process.env, FOUNDATION_EVALS_PLUGIN_DATA: data, FOUNDATION_EVALS_PREVIEW_PORT: '0', FOUNDATION_EVALS_NATIVE_BINARY: '/usr/bin/false' },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  const closed = new Promise(resolve => child.once('close', resolve));
  let diagnostics = '';
  try {
    const port = await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(Error(`Preview startup timeout: ${diagnostics}`)), 8000);
      child.once('error', error => { clearTimeout(timeout); reject(error); });
      child.once('close', () => { clearTimeout(timeout); reject(Error(`Preview exited: ${diagnostics}`)); });
      child.stderr.on('data', chunk => {
        diagnostics += chunk.toString();
        const match = diagnostics.match(/Local MCP preview: http:\/\/127\.0\.0\.1:(\d+)/);
        if (match) { clearTimeout(timeout); resolve(Number(match[1])); }
      });
    });
    const origin = `http://127.0.0.1:${port}`;
    function post(path, body, headers = {}) {
      return new Promise((resolve, reject) => {
        const req = request(`${origin}${path}`, { method: 'POST', headers: { Origin: origin, 'Content-Type': 'application/json', ...headers } }, res => {
          let text = ''; res.setEncoding('utf8'); res.on('data', chunk => { text += chunk; });
          res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, text }));
        });
        req.setTimeout(5000, () => req.destroy(Error('Preview request timeout')));
        req.on('error', reject); req.end(JSON.stringify(body));
      });
    }
    const create = name => ({ jsonrpc: '2.0', method: 'tools/call', params: { name: 'eval_create_project', arguments: { name } } });
    const originalProjects = await readdir(join(data, 'projects'));
    const accepted = await post('/rpc', create('Allowed project'));
    assert.equal(accepted.status, 200, accepted.text);
    assert.equal(JSON.parse(accepted.text).result.structuredContent.project.name, 'Allowed project');
    const exportBody = { params: { contents: [{ resource: { uri: 'file:///allowed.json', text: 'review evidence' } }] } };
    assert.equal((await post('/export', exportBody)).status, 200);
    const invalidExport = await post('/export', { params: { contents: [{ resource: { uri: 'file:///invalid.html', text: '<script>unexpected</script>' } }] } });
    assert.equal(invalidExport.status, 500);
    assert.equal(invalidExport.headers['content-type'], 'application/json');
    assert.equal(invalidExport.headers['x-content-type-options'], 'nosniff');
    assert.equal(JSON.parse(invalidExport.text).error.message, 'Invalid export filename');
    for (const headers of [
      { Origin: 'https://unrelated.example' },
      { Origin: `http://127.0.0.1:${port + 1}` },
      { Origin: 'null' },
      { Origin: '' },
      { Host: `unrelated.example:${port}` },
      { 'Content-Type': 'text/plain' },
    ]) {
      for (const [path, body] of [['/rpc', create('Forbidden project')], ['/export', { params: { contents: [{ resource: { uri: 'file:///forbidden.json', text: 'injected' } }] } }]]) {
        const result = await post(path, body, headers);
        assert.ok([403, 415].includes(result.status), `${path}: ${result.status} ${result.text}`);
      }
    }
    const projects = await readdir(join(data, 'projects'));
    assert.equal(projects.length, originalProjects.length + 1);
    const records = await Promise.all(projects.map(async name => JSON.parse(await readFile(join(data, 'projects', name), 'utf8'))));
    assert.ok(records.some(project => project.name === 'Allowed project'));
    assert.ok(records.every(project => project.name !== 'Forbidden project'));
    assert.deepEqual(await readdir(join(data, 'preview-trace-exports')), ['allowed.json']);
  } finally {
    child.kill('SIGTERM');
    const timeout = setTimeout(() => child.kill('SIGKILL'), 3000);
    await closed; clearTimeout(timeout);
    await rm(data, { recursive: true, force: true });
  }
});
