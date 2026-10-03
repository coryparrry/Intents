export function createViewMotion() {
  let context;
  const clear = () => {
    context?.revert();
    context = undefined;
  };
  return {
    clear,
    start(gsap, animate) {
      clear();
      context = gsap.context(animate);
    }
  };
}

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
