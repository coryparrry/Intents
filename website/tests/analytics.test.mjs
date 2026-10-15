import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { downloadProperties, safeURL, startAnalytics } from '../dist/analytics.mjs';
const origin = 'https://intents-workbench.coryparry.chatgpt.site';
function browser(options = {}) {
  const listeners = new Map();
  const choice = { hidden: true, setAttribute() {}, addEventListener(type, fn) { this[type] = fn; } };
  const scripts = [];
  const win = {
    addEventListener(type, fn) { listeners.set(`window:${type}`, fn); },
    navigator: options.navigator || {},
    location: { href: `${origin}/?analytics_test=1&secret=hidden`, hostname: new URL(options.origin || origin).hostname, reload() { win.reloaded = true; } },
    localStorage: { getItem() { if (options.storageBlocked) throw Error('blocked'); return options.disabled ? 'true' : null; }, setItem(key, value) { if (options.storageBlocked) throw Error('blocked'); win.saved = [key, value]; } },
    document: { querySelector() { return choice; }, createElement() { return {}; }, head: { appendChild(script) { scripts.push(script); } }, addEventListener(type, fn) { listeners.set(type, fn); } },
  };
  return { win, choice, scripts, listeners };
}
const link = (location = 'hero', path = 'tag/v1.4.0') => ({ href: `https://github.com/coryparrry/Intents/releases/${path}`, dataset: { downloadLocation: location } });

test('production initialization queues SDK calls and disables recordings and incidental capture', () => {
  const b = browser();
  const config = startAnalytics(b.win);
  assert.equal(b.scripts.length, 1);
  assert.equal(b.scripts[0].src, 'https://eu-assets.i.posthog.com/static/array.js');
  assert.equal(b.scripts[0].async, true);
  assert.equal(config.cookieless_mode, 'always');
  assert.equal(config.api_host, 'https://eu.i.posthog.com');
  for (const key of ['autocapture', 'capture_exceptions', 'capture_heatmaps', 'capture_dead_clicks', 'capture_performance']) assert.equal(config[key], false);
  assert.equal(config.disable_session_recording, true);
  assert.equal(config.disable_external_dependency_loading, true);
  assert.equal(config.disable_surveys, true);
  assert.equal(config.capture_pageview, false);
  config.loaded(b.win.posthog);
  assert.equal(b.win.posthog[0][0], 'capture');
  assert.equal(b.win.posthog[0][1], '$pageview');
  assert.equal(b.win.posthog[0][2].$current_url, `${origin}/`);
});

test('an opt-out in another tab stops both custom capture and pageleave', () => {
  const b = browser(); const config = startAnalytics(b.win);
  b.win.localStorage.getItem = () => 'true';
  b.listeners.get('window:storage')({ key: 'intents-website-analytics-disabled' });
  assert.equal(config.before_send({ properties: {} }), null);
  b.listeners.get('click')({ type: 'click', target: { closest: () => link() } });
  assert.equal(b.win.posthog.length, 0);
  assert.equal(b.choice.textContent, 'Analytics: off');
});

test('browser privacy signals, opt-out and previews never load the SDK', () => {
  for (const options of [{ navigator: { doNotTrack: '1' } }, { navigator: { globalPrivacyControl: true } }, { disabled: true }, { origin: 'http://localhost:4173' }]) {
    const b = browser(options);
    assert.equal(startAnalytics(b.win), null);
    assert.deepEqual(b.scripts, []);
    assert.equal(b.listeners.has('click'), false);
  }
  assert.ok(startAnalytics(browser({ storageBlocked: true }).win), 'Unavailable preference storage must not break the page');
});

test('all tagged download links are tracked with placement and direct-vs-release intent', () => {
  for (const [page, expectedCount] of [['index.html', 3], ['getting-started.html', 1]]) {
    const html = readFileSync(new URL(`../dist/${page}`, import.meta.url), 'utf8');
    const tags = [...html.matchAll(/<a\b[^>]*data-download-location="([^"]+)"[^>]*>/g)];
    assert.equal(tags.length, expectedCount);
    assert.match(html, /src="\/analytics.mjs"/);
    for (const [tag, placement] of tags) {
      const props = downloadProperties({ href: tag.match(/href="([^"]+)"/)[1], dataset: { downloadLocation: placement } });
      assert.equal(props.download_location, placement);
      assert.equal(props.release_version, 'v1.4.0');
      assert.equal(props.download_type, page === 'index.html' ? 'release_page' : 'disk_image');
    }
  }
  assert.equal(downloadProperties({ href: 'https://example.com', dataset: { downloadLocation: 'hero' } }), null);
  assert.equal(downloadProperties({ href: link().href, dataset: {} }), null);
});

test('nested clicks and middle clicks use immediate unload-safe delivery without stopping navigation', () => {
  const b = browser(); startAnalytics(b.win);
  const target = { closest: () => link() };
  b.listeners.get('click')({ type: 'click', target });
  b.listeners.get('auxclick')({ type: 'auxclick', button: 1, target });
  b.listeners.get('auxclick')({ type: 'auxclick', button: 2, target });
  b.listeners.get('click')({ type: 'click', target: { closest: () => null } });
  assert.equal(b.win.posthog.length, 2);
  for (const capture of b.win.posthog) {
    assert.equal(capture[1], 'website_download_clicked');
    assert.equal(capture[2].download_location, 'hero');
    assert.deepEqual(capture[3], { transport: 'sendBeacon', send_instantly: true });
  }
});

test('event enrichment distinguishes verification traffic and redacts URL credentials and parameters', () => {
  const b = browser(); const config = startAnalytics(b.win);
  const event = config.before_send({ properties: { $current_url: `${origin}/?secret=token&utm_source=release#private`, $referrer: 'https://example.com/?email=private#account', $initial_current_url: `${origin}/?password=hidden` } });
  assert.equal(event.properties.site, 'intents');
  assert.equal(event.properties.analytics_source, 'website');
  assert.equal(event.properties.is_test, true);
  assert.equal(event.properties.$current_url, `${origin}/?utm_source=release`);
  assert.equal(event.properties.$referrer, 'https://example.com/');
  assert.equal(event.properties.$initial_current_url, `${origin}/`);
  assert.equal(safeURL('https://name:password@example.com/#secret'), 'https://example.com/');
  assert.equal(safeURL('not a URL'), '');
});

test('turning analytics off blocks both capture and pageleave immediately and remembers the choice', () => {
  const b = browser(); const config = startAnalytics(b.win);
  assert.equal(b.choice.hidden, false);
  b.choice.click();
  assert.deepEqual(b.win.saved, ['intents-website-analytics-disabled', 'true']);
  assert.equal(b.win.reloaded, true);
  assert.equal(config.before_send({ properties: {} }), null);
  b.listeners.get('click')({ type: 'click', target: { closest: () => link() } });
  assert.equal(b.win.posthog.length, 0);
  const blocked = browser({ navigator: { globalPrivacyControl: true } });
  startAnalytics(blocked.win); blocked.choice.click();
  assert.equal(blocked.win.reloaded, undefined);
  assert.equal(blocked.win.saved, undefined);
});


test('each public page exposes the website privacy notice and the privacy page loads analytics', () => {
  for (const page of ['index.html', 'getting-started.html']) {
    const html = readFileSync(new URL(`../dist/${page}`, import.meta.url), 'utf8');
    assert.match(html, /href="\/privacy\.html"/);
    assert.doesNotMatch(html, /releases\/(?:tag|download)\/v1\.3\.0/);
  }
  const privacy = readFileSync(new URL('../dist/privacy.html', import.meta.url), 'utf8');
  assert.match(privacy, /src="\/analytics.mjs"/);
  assert.match(privacy, /data-analytics-toggle/);
});
