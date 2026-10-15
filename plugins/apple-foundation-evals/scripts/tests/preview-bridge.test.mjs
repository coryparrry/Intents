import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import vm from 'node:vm';

// Exercise the script actually served by preview.mjs. Navigation preserves an
// iframe WindowProxy, so source identity alone must not authorize its new origin.
test('preview bridge requires both its child WindowProxy and same origin', async () => {
  const source = await readFile(new URL('../preview.mjs', import.meta.url), 'utf8');
  const host = source.match(/const host = `([\s\S]*?)`;/)?.[1];
  assert.ok(host, 'Preview host template must exist');
  const script = host.match(/<script>([\s\S]*?)<\/script>/)?.[1];
  assert.ok(script, 'Preview bridge script must exist');
  const origin = 'http://127.0.0.1:4317';
  const posted = [];
  const child = { postMessage: (message, targetOrigin) => posted.push({ message, targetOrigin }) };
  let receive;
  vm.runInNewContext(script, {
    document: { querySelector: () => ({ contentWindow: child }) },
    location: { origin, search: '' },
    URLSearchParams,
    addEventListener: (name, handler) => { assert.equal(name, 'message'); receive = handler; },
    setTimeout: () => {}, // Initialization's follow-up RPC is unrelated to bridge admission.
  });
  assert.equal(typeof receive, 'function');
  const data = { jsonrpc: '2.0', id: 1, method: 'ui/initialize' };
  for (const untrustedOrigin of ['https://unrelated.example', 'null', '', 'http://127.0.0.1:4318']) {
    await receive({ source: child, origin: untrustedOrigin, data });
    assert.equal(posted.length, 0, `Accepted matching child source from ${untrustedOrigin}`);
  }
  await receive({ source: {}, origin, data });
  assert.equal(posted.length, 0, 'Accepted a different source from the preview origin');
  await receive({ source: child, origin, data });
  assert.equal(posted.length, 1);
  assert.equal(posted[0].targetOrigin, origin);
  assert.equal(posted[0].message.id, 1);
  assert.equal(posted[0].message.result.hostInfo.name, 'Local MCP preview');
});
