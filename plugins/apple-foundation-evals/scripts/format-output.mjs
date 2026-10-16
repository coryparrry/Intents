// Keep generated text portable without altering content on nonblank lines.
export function formatOutput(source) {
  return source.replace(/\r\n?/g, "\n").replace(/^[ \t]+$/gm, "").trimEnd() + "\n";
}
