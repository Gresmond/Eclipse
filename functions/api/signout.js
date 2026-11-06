import { answer, fromOurPage, noSessionCookie } from '../_session.js';

export async function onRequestPost({ request }) {
  if (!fromOurPage(request)) return answer(403, { error: 'wrong_origin' });
  return answer(200, { ok: true }, { 'Set-Cookie': noSessionCookie() });
}
