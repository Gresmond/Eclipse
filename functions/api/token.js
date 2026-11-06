import { answer, fromOurPage, noSessionCookie, sessionOf } from '../_session.js';

/// An hour's access to the signed-in person's Drive, for their own page.
export async function onRequestPost({ request, env }) {
  if (!fromOurPage(request)) return answer(403, { error: 'wrong_origin' });
  const session = await sessionOf(request, env);
  if (!session) return answer(401, { error: 'signed_out' });
  let reply;
  try {
    reply = await fetch('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: env.GOOGLE_CLIENT_ID,
        client_secret: env.GOOGLE_CLIENT_SECRET,
        refresh_token: session.refresh,
        grant_type: 'refresh_token',
      }),
    });
  } catch {
    return answer(502, { error: 'google_unreachable' });
  }
  const json = await reply.json().catch(() => ({}));
  if (json.error === 'invalid_grant') {
    return answer(401, { error: 'signed_out' }, { 'Set-Cookie': noSessionCookie() });
  }
  if (!reply.ok || !json.access_token) return answer(502, { error: 'google_refused' });
  return answer(200, { access_token: json.access_token, expires_in: json.expires_in });
}
