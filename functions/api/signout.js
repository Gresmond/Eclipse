import { answer, fetchWithTimeout, fromOurPage, missingEnv, noSessionCookie, sessionOf } from '../_session.js';

export async function onRequestPost({ request, env }) {
  if (!fromOurPage(request)) return answer(403, { error: 'wrong_origin' });
  if (env && !missingEnv(env, ['COOKIE_KEY'])) {
    const session = await sessionOf(request, env);
    if (session?.refresh) {
      try {
        await fetchWithTimeout('https://oauth2.googleapis.com/revoke', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({ token: session.refresh }),
        });
      } catch {
        // Best-effort revocation: the session cookie is still cleared.
      }
    }
  }
  return answer(200, { ok: true }, { 'Set-Cookie': noSessionCookie() });
}
