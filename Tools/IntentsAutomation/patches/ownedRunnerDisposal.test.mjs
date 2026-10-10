import test from 'node:test';
import assert from 'node:assert/strict';
import {disposeOwnedSimulatorRunner, verifyRunnerJobs} from './ownedRunnerDisposal.mjs';
const id = '0CF801C6-B421-4AC1-8889-4AABE24D88F5';
function context() {
 return {device: {id, kind: 'simulator'}, lease: {deviceId: id, sessionId: 'owned', runnerPid: 42, runnerStartTime: 'start-host',
   ownerPid: 40, ownerStartTime: 'start-owner', ownerStateDir: '/private/tmp/owned', ownerToken: 'test-owner', port: 1234, xctestrunPath: '/private/tmp/owned/runner.xctestrun', jsonPath: '/private/tmp/owned/env.json'},
   sessionId: 'owned', hostPID: 42, ownerPID: 40, ownerStartTime: 'start-owner', ownerStateDir: '/private/tmp/owned',
   currentLease() { return structuredClone(this.lease); }, configuredBundles: ['com.callstack.agentdevice.runner', 'com.callstack.agentdevice.runner.uitests.xctrunner']};
}
function successful(args) { return {exitCode: 0, stderr: '', stdout: args[0] === 'listapps' ? '{"subject.App":{}}' : args[0] === 'spawn' ? 'PID\tStatus\tLabel\n123\t0\tUIKitApplication:subject.App[owned]\n' : ''}; }
test('owned disposal uses exact target and SDK runner bundles and observes installed/loaded absence', async () => {
 const calls = []; const receipt = await disposeOwnedSimulatorRunner(context(), async args => {calls.push(args); return successful(args);});
 assert.equal(calls.length, 6); assert.ok(calls.every(args => args[1] === id));
 assert.deepEqual(calls.slice(0,4).map(args => args[0]), ['terminate', 'uninstall', 'terminate', 'uninstall']);
 assert.ok(calls.slice(0,4).every(args => args[2].startsWith('com.callstack.agentdevice.runner')));
 assert.equal(receipt.installedRunnerAbsent, true); assert.equal(receipt.loadedRunnerAbsent, true);
 assert.equal(receipt.hostStartTime, 'start-host'); assert.equal(receipt.ownerDigest.length, 64);
 assert.equal(JSON.stringify(receipt).includes('test-owner'), false);
});
test('foreign missing or changed owner/session/process/configuration stops before device commands', async () => {
 const variants = [c => c.lease = null, c => c.currentLease = () => null, c => c.currentLease = () => ({...c.lease, ownerToken: 'foreign'}),
   c => c.lease.sessionId = 'foreign', c => c.lease.runnerPid++, c => c.lease.runnerStartTime = null,
   c => c.lease.ownerStartTime = 'foreign', c => c.lease.ownerStateDir = '/foreign',
   c => c.configuredBundles.push('subject.App'), c => c.device.kind = 'physical'];
 for(const change of variants) {const c = context(); change(c); let calls = 0;
  await assert.rejects(disposeOwnedSimulatorRunner(c, async () => {calls++; return successful([]);})); assert.equal(calls, 0);}
});
test('ownership lost after a command prevents the next mutation', async () => {
 const c = context(); let calls = 0;
 await assert.rejects(disposeOwnedSimulatorRunner(c, async args => {calls++; c.currentLease = () => ({...c.lease, sessionId: 'new-same-owner'}); return successful(args);}));
 assert.equal(calls, 1);
});
test('uninstall errors and malformed/truncated results never become release', async () => {
 for(const broken of [{exitCode: 1, stdout: '', stderr: 'invalid device'}, {exitCode: 0, stdout: '', stderr: null},
   {exitCode: 0, stdout: 'x'.repeat(1048577), stderr: ''}]) {
  await assert.rejects(disposeOwnedSimulatorRunner(context(), async args => args[0] === 'uninstall' ? broken : successful(args)));
 }
});
test('already absent runner still requires both independent inventories', async () => {
 const c = context(), calls = [];
 const receipt = await disposeOwnedSimulatorRunner(c, async args => {calls.push(args); return args[0] === 'uninstall' ?
  {exitCode: 1, stdout: '', stderr: 'Application is not installed'} : successful(args);});
 assert.equal(receipt.loadedRunnerAbsent, true); assert.equal(calls.length, 6);
});
test('installed app or loaded UIKit job with or without PID retains uncertainty', async () => {
 const runner = 'com.callstack.agentdevice.runner.uitests.xctrunner';
 for(const [operation, text] of [['listapps', JSON.stringify({[runner]: {}})],
  ['spawn', `PID\tStatus\tLabel\n456\t0\tUIKitApplication:${runner}[run]\n`],
  ['spawn', `PID\tStatus\tLabel\n-\t0\tUIKitApplication:${runner}[run]\n`]]) {
  await assert.rejects(disposeOwnedSimulatorRunner(context(), async args => args[0] === operation ? {exitCode: 0, stdout: text, stderr: ''} : successful(args)));
 }
});
test('unknown and partial inventories cannot prove absence', async () => {
 for(const text of ['', '{}', 'PID\tStatus\tLabel', 'PID\tStatus\tLabel\ninvalid\n']) assert.throws(() => verifyRunnerJobs(text));
 for(const text of ['[]', 'null', '{"some":null}', 'broken']) await assert.rejects(disposeOwnedSimulatorRunner(context(), async args =>
  args[0] === 'listapps' ? {exitCode: 0, stdout: text, stderr: ''} : successful(args)));
});
test('same owner with a replaced session or host identity never authorizes disposal', async () => {
 for(const changed of [{sessionId: 'new-session'}, {runnerPid: 99}, {runnerStartTime: 'new-start'}, {port: 4321}, {jsonPath: '/foreign'}]) {
  const c = context(); c.currentLease = () => ({...c.lease, ...changed}); let calls = 0;
  await assert.rejects(disposeOwnedSimulatorRunner(c, async args => {calls++; return successful(args);})); assert.equal(calls, 0);
 }
});
test('bounded SDK plist conversion supports the real app-inventory alternative', async () => {
 const c = context(); let conversions = 0;
 const receipt = await disposeOwnedSimulatorRunner(c, async args => args[0] === 'listapps' ?
  {exitCode: 0, stdout: '{ "subject.App" = { CFBundleIdentifier = "subject.App"; }; }', stderr: ''} : successful(args), async text => {
   assert.ok(text.includes('CFBundleIdentifier')); conversions++; return {exitCode: 0, stdout: '{"subject.App":{}}', stderr: ''};
  });
 assert.equal(conversions, 1); assert.equal(receipt.installedRunnerAbsent, true);
 await assert.rejects(disposeOwnedSimulatorRunner(c, async args => args[0] === 'listapps' ? {exitCode: 0, stdout: 'plist', stderr: ''} : successful(args),
  async () => ({exitCode: 1, stdout: '{}', stderr: ''})));
});
test('real pinned SDK stop path re-enters strict disposal while draining and never deletes lease on repeated failure', async () => {
 const {readFile} = await import('node:fs/promises');
 const source = await readFile(new URL('../node_modules/agent-device/dist/src/runner-client.js', import.meta.url), 'utf8');
 const start = source.indexOf('async function L(e,t,n={})'), end = source.indexOf('function Dn(', start);
 const stopSource = source.slice(start, end); assert.ok(stopSource.includes('r.state===`draining`'));
 const zStart = source.indexOf('async function z(e)'), zEnd = source.indexOf('async function jn(', zStart);
 assert.ok(start >= 0 && end > start && zStart >= 0 && zEnd > zStart);
 const c = context(), session = {...c, deviceId: id, state: 'ready'}, sessions = new Map([[id, session]]);
 let attempts = 0, cleanupCalls = 0, absent = false, leaseDeleted = false;
 const disposal = async r => {
  attempts++; r.state = 'draining';
  await disposeOwnedSimulatorRunner(c, async args => args[0] === 'spawn' && !absent ?
   {exitCode: 0, stderr: '', stdout: 'PID\tStatus\tLabel\n-\t0\tUIKitApplication:com.callstack.agentdevice.runner[owned]\n'} : successful(args));
  leaseDeleted = true; r.state = 'stopped';
 };
 // Evaluate only two exact, trusted, hash-pinned SDK functions in this regression fixture.
 const stop = new Function('j', 'at', 'Wt', `return (${stopSource})`)(sessions, r => ['starting','ready'].includes(r.state), disposal);
 const lock = async (_id, body) => body();
 const close = new Function('R', 'N', 'Qt', 'L', 'Xt', `return (${source.slice(zStart, zEnd)})`)(() => {}, lock, lock, stop, async () => {cleanupCalls++;});
 await assert.rejects(close(id)); assert.equal(attempts, 1); assert.equal(cleanupCalls, 0); assert.equal(leaseDeleted, false);
 await assert.rejects(close(id)); assert.equal(attempts, 2); assert.equal(cleanupCalls, 0); assert.equal(leaseDeleted, false);
 absent = true; await close(id); assert.equal(attempts, 3); assert.equal(leaseDeleted, true); assert.equal(cleanupCalls, 1);
 assert.equal(sessions.size, 0);
});
