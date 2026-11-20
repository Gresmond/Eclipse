// Keeps Eclipse opening without a connection. Always asks the site first, so a
// new version is there on the next load, and falls back on what it last got.
const CACHE_PREFIX = 'eclipse-';
const CACHE_VERSION = '__ECLIPSE_VERSION__';
const cache = CACHE_PREFIX + CACHE_VERSION;
const NETWORK_TIMEOUT_MS = 5000;

const isCritical = (path) =>
  path === 'index.html' ||
  path === 'boot.js' ||
  path === 'sqlite3.wasm' ||
  path === 'flutter_bootstrap.js' ||
  path.endsWith('.wasm') ||
  path.endsWith('.mjs');

self.addEventListener('install', (event) => {
  event.waitUntil(
    (async () => {
      const store = await caches.open(cache);
      let list = await (await fetch('precache.json', { cache: 'no-store' })).json();
      // Refresh fallback engines that this browser used before the update.
      const fallback = new Set();
      const base = self.registration.scope;
      for (const key of await caches.keys()) {
        if (key === cache || !(key === 'eclipse' || key.startsWith(CACHE_PREFIX))) continue;
        for (const request of await (await caches.open(key)).keys()) {
          const url = new URL(request.url);
          if (!url.href.startsWith(base)) continue;
          const path = url.href.slice(base.length).split('?')[0];
          if (/^(main\.dart\.js|canvaskit\/(?:chromium\/)?(?:canvaskit|skwasm_heavy)\.(?:js|wasm))$/.test(path)) fallback.add(path);
        }
      }
      // Flutter 3.47 selects the CanvasKit JS build on Gecko and WebKit.
      if (!/Chrome\/|Chromium\/|Edg\//.test(navigator.userAgent)) {
        list = list.filter((path) => !['main.dart.wasm', 'main.dart.mjs', 'canvaskit/skwasm.js', 'canvaskit/skwasm.wasm'].includes(path));
        fallback.add('main.dart.js');
        fallback.add('canvaskit/canvaskit.js');
        fallback.add('canvaskit/canvaskit.wasm');
      }
      list.push(...fallback);
      const results = await Promise.allSettled(
        list.map((path) => store.add(new Request(path, { cache: 'reload' }))),
      );
      if (results.some((r, i) => r.status === 'rejected' && (isCritical(list[i]) || fallback.has(list[i])))) {
        throw new Error('Critical precache asset failed');
      }
      await self.skipWaiting();
    })(),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      const keys = await caches.keys();
      await Promise.all(
        keys
          .filter((key) => key !== cache && (key === 'eclipse' || key.startsWith(CACHE_PREFIX)))
          .map((key) => caches.delete(key)),
      );
      await self.clients.claim();
    })(),
  );
});

self.addEventListener('fetch', (event) => {
  const { request } = event;
  const url = new URL(request.url);
  if (request.method !== 'GET' || url.origin !== location.origin || url.pathname.startsWith('/api/')) return;
  event.respondWith(
    (async () => {
      const store = await caches.open(cache);
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), NETWORK_TIMEOUT_MS);
      try {
        const reply = await fetch(request, { signal: controller.signal });
        clearTimeout(timer);
        if (reply.status === 200) event.waitUntil(store.put(request, reply.clone()));
        return reply;
      } catch (error) {
        clearTimeout(timer);
        const kept = (await store.match(request, { ignoreSearch: request.mode === 'navigate' })) ??
          (request.mode === 'navigate' ? await store.match('index.html') : undefined);
        if (kept) return kept;
        throw error;
      }
    })(),
  );
});
