import {EngineError} from 'e2e/engine';
import {z} from 'zod';

// These values describe guards, never the subject, node, or proposed input.
export const policyDenialReasons = ['scopeEnvelope', 'actionShape', 'controllerNode',
  'scopeLease', 'actionMismatch', 'deadline', 'budget', 'routeBusy', 'routeRevoked', 'unspecified'] as const;
const reasonSchema = z.enum(policyDenialReasons);
const reviewSchema = z.discriminatedUnion('allowed', [
  z.strictObject({allowed:z.literal(true)}),
  z.strictObject({allowed:z.literal(false),reason:reasonSchema.optional()})
]);
type PolicyDenialReason = z.infer<typeof reasonSchema>;

export class PolicyDeniedError extends EngineError {
  constructor(readonly reason:PolicyDenialReason) {
    super('ENGINE_FAILURE', `Action denied: ${reason}`, {retryable:false});
  }
}

export function requirePolicyApproval(reply:unknown):void {
  const review = reviewSchema.parse(reply);
  if (!review.allowed) throw new PolicyDeniedError(review.reason ?? 'unspecified');
}

export function policyDenialMessage(error:unknown):string|undefined {
  if (!(error instanceof PolicyDeniedError)) return undefined;
  const reason = reasonSchema.safeParse(error.reason);
  return reason.success ? `Action denied: ${reason.data}` : undefined;
}
