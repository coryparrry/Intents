/** Identity data only. The native helper revalidates the real app/process and the caller owns its lease. */
export type MacApplicationTarget = Readonly<{
  bundleId: string;
  canonicalBundlePath: string;
  pid: number;
  processStartIdentity: string;
}>;
export type MacApplicationSelection = Pick<MacApplicationTarget, 'bundleId' | 'canonicalBundlePath'>;

function object(value: unknown, fields: readonly string[]): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value) ||
    ![Object.prototype, null].includes(Object.getPrototypeOf(value)) ||
    Object.keys(value).length !== fields.length || fields.some(field => !Object.hasOwn(value, field))) {
    throw new TypeError('Incomplete or unknown Mac application identity fields');
  }
  return value as Record<string, unknown>;
}

export function parseMacApplicationSelection(value: unknown): MacApplicationSelection {
  const record = object(value, ['bundleId', 'canonicalBundlePath']);
  const {bundleId, canonicalBundlePath} = record;
  if (typeof bundleId !== 'string' || !/^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+$/.test(bundleId) ||
    new TextEncoder().encode(bundleId).length > 256 || typeof canonicalBundlePath !== 'string' ||
    !canonicalBundlePath.startsWith('/') || !canonicalBundlePath.toLowerCase().endsWith('.app') ||
    canonicalBundlePath.includes('\0') || new TextEncoder().encode(canonicalBundlePath).length > 4096 ||
    canonicalBundlePath.split('/').slice(1).some(part => ['', '.', '..'].includes(part))) {
    throw new TypeError('Invalid Mac application selection');
  }
  // This is lexical validation; filesystem aliases and installed identity are checked natively.
  return Object.freeze({bundleId, canonicalBundlePath});
}

export function parseMacApplicationTarget(value: unknown): MacApplicationTarget {
  const record = object(value, ['bundleId', 'canonicalBundlePath', 'pid', 'processStartIdentity']);
  const selection = parseMacApplicationSelection({bundleId: record.bundleId, canonicalBundlePath: record.canonicalBundlePath});
  const {pid, processStartIdentity} = record;
  if (typeof pid !== 'number' || !Number.isInteger(pid) || pid <= 0 || pid > 2147483647 ||
    typeof processStartIdentity !== 'string' || !/^[1-9][0-9]{0,19}:(?:0|[1-9][0-9]{0,5})$/.test(processStartIdentity) ||
    BigInt(processStartIdentity.split(':')[0]!) > 18446744073709551615n) {
    throw new TypeError('Invalid Mac process identity');
  }
  return Object.freeze({...selection, pid, processStartIdentity});
}

export function requireMacApplicationTargetEcho(value: unknown, expected: MacApplicationTarget): MacApplicationTarget {
  const target = parseMacApplicationTarget(value), selected = parseMacApplicationTarget(expected);
  if (target.bundleId !== selected.bundleId || target.canonicalBundlePath !== selected.canonicalBundlePath ||
    target.pid !== selected.pid || target.processStartIdentity !== selected.processStartIdentity) {
    throw new TypeError('Mac operation returned a different application instance');
  }
  return target;
}

export function macApplicationTargetArguments(value: MacApplicationTarget, bundleId: string | undefined, surface: string | undefined): string[] {
  const target = parseMacApplicationTarget(value);
  if (bundleId !== target.bundleId || surface !== 'frontmost-app') {
    throw new TypeError('Mac operation must use its captured app and application surface');
  }
  return ['--target-bundle-path', target.canonicalBundlePath, '--target-pid', String(target.pid),
    '--target-process-start', target.processStartIdentity];
}
