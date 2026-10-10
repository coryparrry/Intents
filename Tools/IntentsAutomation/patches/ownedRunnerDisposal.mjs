// Intents lifecycle patch for agent-device 0.21.20 (MIT).
// Existing SDK device/lease locks and simctl executor retain all device authority.
import {createHash} from 'node:crypto';
const bundles = ['com.callstack.agentdevice.runner', 'com.callstack.agentdevice.runner.uitests.xctrunner'];
function requireOwnership(context) {
 const {device, lease, sessionId, hostPID, ownerPID, ownerStartTime, ownerStateDir, currentLease, configuredBundles} = context;
 const live = typeof currentLease === 'function' ? context.currentLease() : null;
 const fields = ['deviceId', 'ownerToken', 'ownerPid', 'ownerStartTime', 'ownerStateDir', 'sessionId',
  'runnerPid', 'runnerStartTime', 'port', 'xctestrunPath', 'jsonPath', 'simulatorSetPath'];
 if(device?.kind !== 'simulator' || !/^[A-Fa-f0-9-]{36}$/.test(device.id) || !lease ||
   lease.deviceId !== device.id || lease.sessionId !== sessionId || typeof sessionId !== 'string' || !sessionId ||
   !Number.isSafeInteger(hostPID) || hostPID <= 0 || lease.runnerPid !== hostPID ||
   typeof lease.runnerStartTime !== 'string' || !lease.runnerStartTime ||
   lease.ownerPid !== ownerPID || !Number.isSafeInteger(ownerPID) || ownerPID <= 0 ||
   typeof ownerStartTime !== 'string' || !ownerStartTime || lease.ownerStartTime !== ownerStartTime ||
   typeof ownerStateDir !== 'string' || !ownerStateDir.startsWith('/') || lease.ownerStateDir !== ownerStateDir ||
   typeof lease.ownerToken !== 'string' || !lease.ownerToken || !live || fields.some(key => live[key] !== lease[key]) ||
   !Number.isSafeInteger(lease.port) || lease.port < 1 || lease.port > 65535 ||
   [lease.xctestrunPath, lease.jsonPath].some(path => typeof path !== 'string' || !path.startsWith('/')) ||
   !Array.isArray(configuredBundles) || configuredBundles.length !== bundles.length ||
   new Set(configuredBundles).size !== bundles.length || configuredBundles.some(id => !bundles.includes(id))) {
  throw new Error('Intents: simulator runner ownership is unresolved');
 }
}
function result(value, maximum = 1048576) {
 if(!value || !Number.isSafeInteger(value.exitCode) || typeof value.stdout !== 'string' || typeof value.stderr !== 'string' ||
   Buffer.byteLength(value.stdout) + Buffer.byteLength(value.stderr) > maximum) throw new Error('Intents: invalid runner cleanup result');
 return value;
}
export function verifyRunnerJobs(text, identifiers = bundles) {
 if(typeof text !== 'string' || Buffer.byteLength(text) > 1048576 || !text.endsWith('\n')) throw new Error('Intents: incomplete simulator job inventory');
 const lines = text.split('\n');
 if(lines.shift() !== 'PID\tStatus\tLabel' || lines.pop() !== '') throw new Error('Intents: unknown simulator job inventory');
 for(const line of lines) {
  const fields = line.split('\t');
  if(fields.length !== 3 || !/^(?:-|[1-9][0-9]*)$/.test(fields[0]) || !/^-?[0-9]+$/.test(fields[1]) || !fields[2]) throw new Error('Intents: malformed simulator job inventory');
  if(identifiers.some(id => fields[2].startsWith(`UIKitApplication:${id}[`))) throw new Error('Intents: owned UIKit runner remains loaded');
 }
}
export async function disposeOwnedSimulatorRunner(context, runSimctl, convertPlist) {
 requireOwnership(context);
 const outcomes = [];
 for(const bundleID of bundles) {
  requireOwnership(context);
  const termination = result(await runSimctl(['terminate', context.device.id, bundleID]));
  requireOwnership(context);
  const uninstall = result(await runSimctl(['uninstall', context.device.id, bundleID]));
  // Terminate may report already absent. An unrelated uninstall failure is never treated as absence.
  const explicitlyAbsent = /(?:not installed|found nothing)/i.test(uninstall.stdout + '\n' + uninstall.stderr);
  if(uninstall.exitCode !== 0 && !explicitlyAbsent) throw new Error('Intents: owned runner uninstall failed');
  outcomes.push({bundleID, terminateExit: termination.exitCode, uninstallExit: uninstall.exitCode});
 }
 requireOwnership(context);
 const inventory = result(await runSimctl(['listapps', context.device.id]), 16 * 1048576);
 if(inventory.exitCode !== 0) throw new Error('Intents: simulator app inventory failed');
 let installed;
 try { installed = JSON.parse(inventory.stdout); }
 catch {
  if(typeof convertPlist !== 'function') throw new Error('Intents: app inventory format unqualified');
  requireOwnership(context);
  const converted = result(await convertPlist(inventory.stdout), 16 * 1048576);
  if(converted.exitCode !== 0) throw new Error('Intents: app inventory conversion failed');
  installed = JSON.parse(converted.stdout);
 }
 if(!installed || typeof installed !== 'object' || Array.isArray(installed) || Object.keys(installed).length > 5000 ||
   Object.values(installed).some(value => !value || typeof value !== 'object' || Array.isArray(value)) ||
   bundles.some(id => Object.hasOwn(installed, id))) throw new Error('Intents: runner installation absence unproved');
 requireOwnership(context);
 const jobs = result(await runSimctl(['spawn', context.device.id, 'launchctl', 'list']));
 if(jobs.exitCode !== 0) throw new Error('Intents: simulator job inventory failed');
 verifyRunnerJobs(jobs.stdout);
 requireOwnership(context);
 return {schemaVersion: 1, patchVersion: 'intents-owned-disposal-3', deviceID: context.device.id,
   sessionID: context.sessionId, ownerPID: context.ownerPID, ownerStartTime: context.ownerStartTime,
   ownerDigest: createHash('sha256').update(context.lease.ownerToken).digest('hex'),
   hostPID: context.hostPID, hostStartTime: context.lease.runnerStartTime, outcomes,
   installedRunnerAbsent: true, loadedRunnerAbsent: true};
}
