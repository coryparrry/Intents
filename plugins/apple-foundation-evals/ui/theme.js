// Standard MCP Apps host context: initialization and partial theme updates.
/** Applies partial host theme, CSS-variable and font updates while retaining values omitted from the context. */
export function applyHostContext(context, document) {
  if (!context || typeof context !== 'object') return;
  const root = document.documentElement;
  if (context.theme === 'light' || context.theme === 'dark') {
    root.dataset.theme = context.theme;
    root.style.colorScheme = context.theme;
  }
  for (const [name, value] of Object.entries(context.styles?.variables || {})) {
    if (name.startsWith('--') && typeof value === 'string') root.style.setProperty(name, value);
  }
  const fonts = context.styles?.css?.fonts;
  if (typeof fonts === 'string') {
    let style = document.getElementById('mcp-host-fonts');
    if (!style) {
      style = document.createElement('style'); style.id = 'mcp-host-fonts';
      document.head.append(style);
    }
    style.textContent = fonts;
  }
}
