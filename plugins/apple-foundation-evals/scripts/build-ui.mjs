import { readFile, writeFile, rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import postcss from "postcss";
import { build } from "vite";
import tailwindcss from "@tailwindcss/vite";
import { writeUILicenses } from "./ui-licenses.mjs";
import { formatOutput } from "./format-output.mjs";
const root = fileURLToPath(new URL("../", import.meta.url));
// Existing advanced evaluation views remain isolated from the component library.
const legacy = postcss.parse(
  await readFile(resolve(root, "ui/styles.css"), "utf8"),
);
legacy.walkRules((rule) => {
  if (rule.parent?.type === "atrule" && /keyframes$/.test(rule.parent.name))
    return;
  if (
    rule.selector === ":root" ||
    rule.selector === "html" ||
    rule.selector === "body"
  ) {
    rule.remove();
    return;
  }
  rule.selector = rule.selectors
    .map((selector) => `.legacy-view ${selector}`)
    .join(",");
});
legacy.walkDecls((declaration) => {
  declaration.value = declaration.value
    .replaceAll("var(--muted)", "var(--muted-foreground)")
    .replaceAll("var(--accent)", "var(--primary)");
});
await writeFile(resolve(root, "ui/react/legacy.css"), formatOutput(legacy.toString()));
const output = resolve(root, ".ui-build");
const result = await build({
  configFile: false,
  root,
  logLevel: "warn",
  plugins: [tailwindcss()],
  resolve: { alias: { "@": resolve(root, "ui/react") } },
  build: {
    outDir: output,
    emptyOutDir: true,
    cssCodeSplit: false,
    assetsInlineLimit: Infinity,
    rollupOptions: {
      input: resolve(root, "ui/react/entry.tsx"),
      output: {
        entryFileNames: "workspace.js",
        assetFileNames: "workspace.[ext]",
      },
    },
  },
});
await writeUILicenses(root, result);
const [template, css, script] = await Promise.all(
  [
    "ui/workspace.html",
    ".ui-build/workspace.css",
    ".ui-build/workspace.js",
  ].map((file) => readFile(resolve(root, file), "utf8")),
);
await writeFile(
  resolve(root, "ui/app.html"),
  formatOutput(template
    .replace("/* STYLES */", () => css)
    .replace("/* SCRIPT */", () => script.replace(/<\/script/gi, "<\\/script"))),
);
await rm(output, { recursive: true, force: true });
console.log("Built offline shadcn workspace.");
