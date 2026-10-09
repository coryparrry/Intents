// Pure export-resolution check. No client, daemon, helper or target activation.
import assert from 'node:assert/strict';
import * as childProcess from 'node:child_process';
import {createRequire, syncBuiltinESMExports} from 'node:module';
import {readFile} from 'node:fs/promises';
import {resolve, join} from 'node:path';
import {pathToFileURL} from 'node:url';

const directory = resolve(process.argv[2]);
const receipt = JSON.parse(await readFile(join(directory, 'intents-private-runtime.json'), 'utf8'));
assert.equal(receipt.artifactVariant, 'private-owned-mac-source');
assert.equal(receipt.customerRuntimeEnabled, false);
assert.equal(receipt.hardwareQualified, false);
assert.equal(process.env.AGENT_DEVICE_MACOS_HELPER_BIN, join(directory, receipt.helperRelativePath));
const packagePath = join(directory, 'agent-device');
const metadata = JSON.parse(await readFile(join(packagePath, 'package.json'), 'utf8'));
const processModule = createRequire(import.meta.url)('node:child_process');
let processAttempts = 0, networkAttempts = 0;
for (const name of ['spawn', 'spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync', 'fork']) {
  processModule[name] = () => {processAttempts++; throw new Error('Export import attempted process activation');};
}
syncBuiltinESMExports();
assert.equal(childProcess.spawn, processModule.spawn);
globalThis.fetch = () => {networkAttempts++; throw new Error('Export import attempted network activation');};
const exports = [];
for (const [name, contract] of Object.entries(metadata.exports)) {
  assert.ok(contract.import.startsWith('./dist/'));
  const module = await import(pathToFileURL(join(packagePath, contract.import)).href);
  if (name === '.') assert.equal(typeof module.createAgentDeviceClient, 'function');
  exports.push(name);
}
assert.equal(processAttempts, 0);
assert.equal(networkAttempts, 0);
console.log(JSON.stringify({artifactVariant:receipt.artifactVariant, exports, processAttempts, networkAttempts,
  customerRuntimeEnabled:false, hardwareQualified:false, helperInvoked:false}));
