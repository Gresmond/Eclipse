import { claimsOf, noStateCookie, seal, sessionCookie, stateFrom, unseal } from '../../_session.js';

const backTo = (path, cookies) => {
  const headers = new Headers({ Location: path, 'Cache-Control': 'no-store' });
  for (const c of cookies) headers.append('Set-Cookie', c);
  return new Response(null, { status: 302, headers });
};

const failed = (why) => backTo(`/welcome.html?error=${why}`, [noStateCookie()]);

export async function onRequestGet({ request, env }) {
  const url = new URL(request.url);
  const sealed = stateFrom(request);
  const started = sealed ? await unseal(env, sealed) : null;
  // Only the browser that started this sign-in can finish it.
  if (!started || started.state !== url.searchParams.get('state')) return failed('expired');
  const code = url.searchParams.get('code');
  if (!code) return failed('cancelled');

  let tokens;
  try {
    const reply = await fetch('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        code,
        client_id: env.GOOGLE_CLIENT_ID,
        client_secret: env.GOOGLE_CLIENT_SECRET,
        redirect_uri: `${url.origin}/api/auth/callback`,
        grant_type: 'authorization_code',
        code_verifier: started.verifier,
      }),
    });
    if (!reply.ok) return failed('google');
    tokens = await reply.json();
  } catch {
    return failed('google');
  }
  const claims = claimsOf(tokens.id_token ?? '');
  if (!tokens.refresh_token || !claims.email || !claims.sub) return failed('google');
  const granted = (tokens.scope ?? '').split(' ');
  if (!granted.includes('https://www.googleapis.com/auth/drive.appdata')) return failed('drive');

  const session = await seal(env, {
    refresh: tokens.refresh_token,
    email: claims.email,
    id: claims.sub,
    journalAccess: granted.includes('https://www.googleapis.com/auth/drive.file'),
  });
  return backTo('/', [sessionCookie(session), noStateCookie()]);
}
