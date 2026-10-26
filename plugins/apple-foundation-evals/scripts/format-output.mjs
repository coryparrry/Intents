// Keep generated text portable without altering content on nonblank lines.
/** Normalize line endings, remove whitespace-only line contents, and leave exactly one final newline. */
export function formatOutput(source) {
  return source.replace(/\r\n?/g, "\n").replace(/^[ \t]+$/gm, "").trimEnd() + "\n";
}
