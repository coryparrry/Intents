# Intents showcase

A static, responsive showcase of the current native Intents interface. The report,
workflow trace, and Intent Lab examples are rendered as HTML and CSS, using the
native app's icon assets, labels, design tokens, and recorded example outputs.

## Local preview

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory dist
```

Open `http://127.0.0.1:4173/`. No package installation is required. After changing
`dist/styles.css` or `dist/native.css`, run `node scripts/inline-styles.mjs` to
refresh the exact CSS embedded in the homepage. Keeping it inline removes two
render-blocking requests while preserving the authored cascade and first paint.

## Checks

```sh
node --check dist/app.js
node --check dist/demo-data.mjs
node scripts/inline-styles.mjs --check
node --test tests/*.test.mjs
```

`dist/` is the entire published artifact. `.openai/hosting.json` identifies the
Sites project. It contains no runtime secrets. The bundled Sites workflow owns
source synchronization and publication.

## Content and visual provenance

- Native app: current Intents development build and `WorkspaceStyle.swift`,
  inspected on 2 October 2026. Neutral canvas `#f5f5f7`, white panels, 12px panel
  corners, 8px control corners, 28px page padding, macOS system fonts and blue.
- Report: saved **Conversation behaviour** evaluation from 17 September 2026,
  17:34. All three prompts, reference answers, model outputs and judge explanations
  were transcribed from the actual app, including imperfect model responses.
- Trace: the same saved run, **Latest preference wins**, 13 measured spans.
  Expanded-scale bar placement follows the native view. Some inspector end
  times are rounded from the recorded start plus duration; displayed timings
  are not intended as performance benchmarks.
- Intent Lab: the real **PR54 physical read-only check** test fixture. These are
  static examples, not live model execution, Siri calls, or device connections.
- Reference direction: [Inspora](https://www.inspora.design/?category=Web), including
  its glassmorphism animation example: restrained depth, controlled transitions,
  clear typographic hierarchy. No third-party artwork was copied.
- Desktop previews retain the native interface geometry. On small screens the
  sidebar is hidden and tables scroll horizontally to preserve readable controls.
  Browser rendering approximates native materials; no screenshot is passed off
  as an interactive code render.

## Dependencies and licences

- GSAP **3.15.0**, from the official npm package. Local `gsap.min.js` and
  `ScrollTrigger.min.js`; package licence: https://gsap.com/standard-license.
  Copyright notices are preserved in both files. No runtime CDN dependency.
- Lucide Static **1.16.0**, the same version used by the native app. Symbols are
  extracted from its original SVGs. ISC licence in `dist/vendor/LUCIDE-LICENSE.txt`.
- Intents icon and app example: the Intents repository, MIT licence.
- System fonts only. No analytics, external form, remote model call, or cookie.

Motion follows the operating system's reduced-motion preference. The page also
has a pause control with an optional local preference. App selection, filtering,
and search remain available when motion is paused.

## Search and AI discovery

The homepage contains its marketing content in static HTML, with canonical and
social metadata and Schema.org JSON-LD for the website, app, creator, and source
repository. No JavaScript is needed to read the product information.

The icon has responsive PNG sizes generated from the original app asset, plus a
96px favicon. The original 256px icon remains the social/structured-data image.
The below-fold icon loads lazily. A module preload discovers demo data in parallel
with the app script, and ResizeObserver supplies preview geometry without an
eager synchronous layout read.

- `dist/robots.txt` permits crawlers and advertises the sitemap.
- `dist/sitemap.xml` lists only the canonical HTML page. Update `lastmod` when
  its substantive content changes, not on every deployment.
- `dist/llms.txt` is a concise reading guide following the optional llms.txt
  proposal. It is not an indexing requirement or a ranking guarantee.
- `dist/index.html.md` is a linked Markdown product overview. Keep its facts
  and the JSON-LD consistent with the visible site and current product.
- `.openai/hosting.json` disables the homepage fallback for nonexistent URLs,
  so missing pages return HTTP 404 instead of duplicate homepage content.
- Alternate and canonical links are in the HTML head. Sites serves the text
  files with their appropriate content types; its static deployment does not
  apply Cloudflare `_headers` files.

For anonymous production delivery checks after publication:

```sh
node scripts/check-discovery.mjs
```

Public Sites access is required. The checks use representative crawler
user-agent headers; they do not prove visits from real crawler IPs, indexing,
rankings, or inclusion in AI answers. Search Console / Bing Webmaster ownership
verification and sitemap submission can be completed by the domain owner; no
verification token has been invented or added to this site.

References: [Google AI search guidance](https://developers.google.com/search/docs/appearance/ai-features),
[OpenAI crawlers](https://developers.openai.com/api/docs/bots),
[Anthropic crawlers](https://support.claude.com/en/articles/8896518-does-anthropic-crawl-data-from-the-web-and-how-can-site-owners-block-the-crawler),
[llms.txt proposal](https://llmstxt.org/), and [Schema.org SoftwareApplication](https://schema.org/SoftwareApplication).
