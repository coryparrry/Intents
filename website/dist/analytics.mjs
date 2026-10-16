const PROJECT_TOKEN = 'phc_r7Y2URVyeAbu5eyZJjPHCU7RGDX4aTVCJqsUZrqSgahN';
const SITE_HOST = 'intents-workbench.coryparry.chatgpt.site';
const OPT_OUT_KEY = 'intents-website-analytics-disabled';
const CAMPAIGN_KEYS = ['utm_source', 'utm_medium', 'utm_campaign', 'utm_content', 'utm_term'];

export function safeURL(value, base) {
  try {
    const url = new URL(value, base);
    const campaign = new URLSearchParams();
    for (const key of CAMPAIGN_KEYS) {
      if (url.searchParams.has(key)) campaign.set(key, url.searchParams.get(key).slice(0, 200));
    }
    url.username = '';
    url.password = '';
    url.hash = '';
    url.search = campaign.toString();
    return url.href;
  } catch { return ''; }
}

export function downloadProperties(link, base) {
  if (!link?.dataset?.downloadLocation) return null;
  try {
    const url = new URL(link.href, base);
    if (url.origin !== 'https://github.com' || !url.pathname.startsWith('/coryparrry/Intents/releases/')) return null;
    const direct = url.pathname.startsWith('/coryparrry/Intents/releases/download/');
    return {
      download_location: link.dataset.downloadLocation,
      download_type: direct ? 'disk_image' : 'release_page',
      download_url: safeURL(url.href),
      release_version: url.pathname.split('/')[5] || 'latest',
      platform: 'macOS',
    };
  } catch { return null; }
}

export function startAnalytics(win) {
  const { document: doc, navigator: nav, location } = win;
  const isTest = new URL(location.href).searchParams.get('analytics_test') === '1';
  let disabled = false;
  try { disabled = win.localStorage.getItem(OPT_OUT_KEY) === 'true'; } catch {}
  const privacySignal = nav.doNotTrack === '1' || win.doNotTrack === '1' || nav.globalPrivacyControl === true;
  const preference = doc.querySelector('[data-analytics-toggle]');
  win.addEventListener('storage', event => {
    if (event.key !== OPT_OUT_KEY && event.key !== null) return;
    try { disabled = win.localStorage.getItem(OPT_OUT_KEY) === 'true'; } catch { return; }
    if (preference) {
      preference.textContent = disabled || privacySignal ? 'Analytics: off' : 'Analytics: on';
      preference.setAttribute('aria-pressed', String(!disabled && !privacySignal));
    }
    // A tab opened while opted out has not loaded the SDK yet.
    if (!disabled && !privacySignal && !win.posthog) location.reload();
  });
  if (preference) {
    preference.hidden = false;
    preference.textContent = disabled || privacySignal ? 'Analytics: off' : 'Analytics: on';
    preference.setAttribute('aria-pressed', String(!disabled && !privacySignal));
    preference.addEventListener('click', () => {
      if (privacySignal) {
        preference.textContent = 'Analytics: off (browser preference)';
        return;
      }
      disabled = !disabled;
      preference.textContent = disabled ? 'Analytics: off' : 'Analytics: on';
      preference.setAttribute('aria-pressed', String(!disabled));
      try {
        win.localStorage.setItem(OPT_OUT_KEY, String(disabled));
        location.reload();
      } catch {
        // Keep the choice effective on this page even when storage is unavailable.
        if (!disabled) preference.textContent = 'Analytics: off (reload to enable)';
      }
    });
  }
  if (location.hostname !== SITE_HOST || disabled || privacySignal) return null;

  const config = {
    api_host: 'https://eu.i.posthog.com',
    ui_host: 'https://eu.posthog.com',
    defaults: '2026-05-30',
    cookieless_mode: 'always',
    person_profiles: 'identified_only',
    autocapture: false,
    capture_pageview: false,
    capture_pageleave: true,
    disable_session_recording: true,
    // Keep project-level recording/logging defaults from loading extra SDKs.
    disable_external_dependency_loading: true,
    disable_surveys: true,
    capture_exceptions: false,
    capture_heatmaps: false,
    capture_dead_clicks: false,
    rageclick: false,
    capture_performance: false,
    advanced_disable_feature_flags: true,
    respect_dnt: true,
    before_send(event) {
      if (!event || disabled) return null;
      const props = event.properties;
      props.site = 'intents';
      props.analytics_source = 'website';
      props.is_test = isTest;
      for (const key of Object.keys(props)) {
        if (/url|referrer/i.test(key) && typeof props[key] === 'string' && /^https?:\/\//.test(props[key])) {
          props[key] = safeURL(props[key]);
        }
      }
      return event;
    },
    loaded(posthog) {
      posthog.capture('$pageview', { $current_url: safeURL(location.href) });
    },
  };

  // The official HTML snippet's queue contract keeps initialization asynchronous.
  // Calls made while its SDK loads are replayed without blocking links or the demo.
  const posthog = win.posthog = [];
  posthog._i = [[PROJECT_TOKEN, config, 'posthog']];
  posthog.__SV = 1;
  posthog.capture = (...args) => posthog.push(['capture', ...args]);
  const script = doc.createElement('script');
  script.async = true;
  script.crossOrigin = 'anonymous';
  script.src = 'https://eu-assets.i.posthog.com/static/array.js';
  doc.head.appendChild(script);

  const trackDownload = event => {
    if (disabled || (event.type === 'auxclick' && event.button !== 1)) return;
    const properties = downloadProperties(event.target.closest?.('a[data-download-location]'), location.href);
    if (properties) win.posthog.capture('website_download_clicked', properties, { transport: 'sendBeacon', send_instantly: true });
  };
  doc.addEventListener('click', trackDownload);
  doc.addEventListener('auxclick', trackDownload);
  return config;
}

if (typeof window !== 'undefined') startAnalytics(window);
