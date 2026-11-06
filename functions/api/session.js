import { answer, sessionOf } from '../_session.js';

/// Who's signed in, without what signs them in.
export async function onRequestGet({ request, env }) {
  const session = await sessionOf(request, env);
  if (!session) return answer(401, { error: 'signed_out' });
  return answer(200, { email: session.email, id: session.id, journalAccess: session.journalAccess });
}
