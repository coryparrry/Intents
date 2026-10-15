import { readFile, readdir, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { formatOutput } from "./format-output.mjs";

export async function writeUILicenses(root, result) {
  const directories = new Set([
    "node_modules/tw-animate-css",
  ]);
  for (const bundle of Array.isArray(result) ? result : [result]) {
    for (const chunk of bundle.output || []) {
      for (const id of Object.keys(chunk.modules || {})) {
        const match = id.match(/node_modules\/(?:@[^/]+\/)?[^/]+/g)?.at(-1);
        if (match) directories.add(match);
      }
    }
  }
  const notices = [
    "Third-party software bundled in the Foundation Evals UI.\nGenerated from the installed package licenses.",
  ];
  const shadcn = JSON.parse(await readFile(resolve(root, "ui/vendor/shadcn-provenance.json"), "utf8"));
  notices.push(`${shadcn.package} ${shadcn.version} (MIT)\n${await readFile(resolve(root, "ui/vendor", shadcn.license), "utf8")}`);
  for (const directory of [...directories].sort()) {
    const path = resolve(root, directory);
    const metadata = JSON.parse(
      await readFile(resolve(path, "package.json"), "utf8"),
    );
    const files = (await readdir(path))
      .filter((name) => /^(licen[sc]e|copying|notice)(\.|$)/i.test(name))
      .sort();
    const licenses = await Promise.all(
      files.map((file) => readFile(resolve(path, file), "utf8")),
    );
    notices.push(
      `${metadata.name} ${metadata.version} (${metadata.license || "see license"})\n${licenses.join("\n")}`,
    );
  }
  await writeFile(
    resolve(root, "ui/vendor/THIRD-PARTY-NOTICES.txt"),
    formatOutput(notices.join("\n\n----------------------------------------\n\n")),
  );
}
