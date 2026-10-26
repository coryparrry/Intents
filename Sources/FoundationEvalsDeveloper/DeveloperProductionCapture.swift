#if canImport(ProductionEvals)
import ProductionEvals
/// The same opt-in capture contract used by the desktop and standalone batch worker.
/// Capture starts disabled. The integrating app owns consent, the sanitizer and the
/// metadata allowlist. Enabled capture stores sanitized prompt/output/feedback and
/// keyed pseudonyms for event/source identifiers in local JSONL; it sends no network traffic.
public typealias DeveloperProductionCapture = ProductionEvals.DeveloperProductionCapture
#endif
