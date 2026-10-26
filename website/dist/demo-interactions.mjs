/** Own one reversible GSAP context so changing views clears animations and their inline effects. */
export function createViewMotion() {
  let context;
  /** Revert the active animation context and release the reference; safely do nothing when none exists. */
  const clear = () => {
    context?.revert();
    context = undefined;
  };
  return {
    clear,
    /** Revert previous view animation before capturing the supplied animation in a new GSAP context. */
    start(gsap, animate) {
      clear();
      context = gsap.context(animate);
    }
  };
}

/** Attempt a clipboard write, convert rejection to a failure result, and notify only while the originating UI is still current. */
export async function copyCurrentResponse({text, writeText, isCurrent, onResult}) {
  let copied;
  try {
    await writeText(text);
    copied = true;
  } catch {
    copied = false;
  }
  if (isCurrent()) onResult(copied);
}
