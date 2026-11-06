// Keeps Eclipse opening without a connection. Always asks the site first, so a
// new version is there on the next load, and falls back on what it last got.
const cache = 'eclipse';

self.addEventListener('install', (event) => {
  event.waitUntil(
    (async () => {
      const store = await caches.open(cache);
      const list = await (await fetch('precache.json', { cache: 'no-store' })).json();
      // One failing doesn't stop the rest; it's cached when next fetched.
      await Promise.allSettled(list.map((path) => store.add(new Request(path, { cache: 'reload' }))));
      await self.skipWaiting();
    })(),
  );
});

self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

self.addEventListener('fetch', (event) => {
  const { request } = event;
  const url = new URL(request.url);
  if (request.method !== 'GET' || url.origin !== location.origin || url.pathname.startsWith('/api/')) return;
  event.respondWith(
    (async () => {
      const store = await caches.open(cache);
      try {
        const reply = await fetch(request);
        if (reply.ok) await store.put(request, reply.clone());
        return reply;
      } catch (error) {
        const kept = (await store.match(request, { ignoreSearch: request.mode === 'navigate' })) ??
          (request.mode === 'navigate' ? await store.match('index.html') : undefined);
        if (kept) return kept;
        throw error;
      }
    })(),
  );
});
