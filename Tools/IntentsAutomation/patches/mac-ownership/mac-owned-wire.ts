import {parseMacApplicationSelection, parseMacApplicationTarget, requireMacApplicationTargetEcho,
  type MacApplicationSelection, type MacApplicationTarget} from './mac-application-target.ts';

export function requireMacOpenEcho(value: unknown, selection: MacApplicationSelection): MacApplicationTarget {
  const expected = parseMacApplicationSelection(selection), target = parseMacApplicationTarget(value);
  if (target.bundleId !== expected.bundleId || target.canonicalBundlePath !== expected.canonicalBundlePath) {
    throw new TypeError('Mac open returned a different selected application');
  }
  return target;
}

export function requireMacPressEcho(value: Record<string, unknown>, target: MacApplicationTarget,
  point: {x: number; y: number}): void {
  requireMacApplicationTargetEcho(value.applicationTarget, target);
  if (value.disposition !== 'submittedUnconfirmed' || value.releaseSubmitted !== true ||
    value.x !== point.x || value.y !== point.y) {
    throw new TypeError('Mac input submission is incomplete or unconfirmed');
  }
}

export function validateMacOwnedPress(x: number, y: number, options: {
  holdMs?: number; clicks?: number; doubleClick?: boolean; intervalMs?: number;
}): void {
  const hold = options.holdMs ?? 60, clicks = options.clicks ?? 1, interval = options.intervalMs ?? 120;
  if (![x, y].every(value => Number.isFinite(value) && Math.abs(value) <= 1_000_000) ||
    !Number.isInteger(hold) || hold < 0 || hold > 5000 || !Number.isInteger(clicks) || clicks < 1 || clicks > 8 ||
    !Number.isInteger(interval) || interval < 0 || interval > 1000 ||
    (options.doubleClick !== undefined && typeof options.doubleClick !== 'boolean') ||
    clicks * (options.doubleClick ? 2 * Math.max(hold, 40) + 80 : Math.max(hold, 40)) + (clicks - 1) * interval > 60_000) {
    throw new TypeError('Mac press exceeds the bounded native schedule');
  }
}
