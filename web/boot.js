// Sends a first-time visitor to the welcome page without loading the whole
// app, and otherwise loads it. Offline, or if the question fails, it loads
// the app, which can tell what to do.
(async () => {
  let here = false;
  try {
    here = localStorage.getItem('eclipse-here') === '1';
  } catch {}
  if (!here) {
    try {
      const reply = await fetch('/api/session', { cache: 'no-store' });
      if (reply.status === 401) {
        location.replace('/welcome.html');
        return;
      }
    } catch {}
  }
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('sw.js').catch(() => {});
  }
  const script = document.createElement('script');
  script.src = 'flutter_bootstrap.js';
  script.async = true;
  document.body.append(script);
})();
