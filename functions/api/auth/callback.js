import {
  answer,
  claimsOf,
  missingEnv,
  noStateCookie,
  seal,
  SECURITY_HEADERS,
  sessionCookie,
  SESSION_PURPOSE,
  SIGN_IN_PURPOSE,
  stateFrom,
  unseal,
} from '../../_session.js';

const backTo = (path, cookies) => {
  const headers = new Headers({ Location: path, ...SECURITY_HEADERS });
  for (const c of cookies) headers.append('Set-Cookie', c);
  return new Response(null, { status: 302, headers });
};

const failed = (why) => backTo(`/welcome.html?error=${why}`, [noStateCookie()]);

export async function onRequestGet({ request, env }) {
  if (missingEnv(env, ['COOKIE_KEY', 'GOOGLE_CLIENT_ID', 'GOOGLE_CLIENT_SECRET'])) {
    return answer(500, { error: 'misconfigured' });
  }
  const url = new URL(request.url);
  const sealed = stateFrom(request);
  const started = sealed ? await unseal(env, sealed, SIGN_IN_PURPOSE) : null;
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
  const now = Math.floor(Date.now() / 1000);
  const validIssuer = claims.iss === 'https://accounts.google.com' || claims.iss === 'accounts.google.com';
  if (
    !tokens.refresh_token ||
    !validIssuer ||
    claims.aud !== env.GOOGLE_CLIENT_ID ||
    typeof claims.exp !== 'number' ||
    claims.exp <= now ||
    claims.email_verified === false ||
    !claims.email ||
    !claims.sub
  ) {
    return failed('google');
  }
  const granted = (tokens.scope ?? '').split(' ');
  if (!granted.includes('https://www.googleapis.com/auth/drive.appdata')) return failed('drive');

  const session = await seal(
    env,
    {
      refresh: tokens.refresh_token,
      email: claims.email,
      id: claims.sub,
      journalAccess: granted.includes('https://www.googleapis.com/auth/drive.file'),
    },
    SESSION_PURPOSE,
  );
  return backTo('/', [sessionCookie(session), noStateCookie()]);
}
