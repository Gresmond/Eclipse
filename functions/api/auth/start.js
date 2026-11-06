import { challengeFor, randomText, seal, stateCookie } from '../../_session.js';

const scopes = [
  'openid',
  'email',
  'https://www.googleapis.com/auth/drive.appdata',
  'https://www.googleapis.com/auth/drive.file',
];

export async function onRequestGet({ request, env }) {
  const origin = new URL(request.url).origin;
  const state = randomText(16);
  const verifier = randomText(48);
  const page = new URL('https://accounts.google.com/o/oauth2/v2/auth');
  page.search = new URLSearchParams({
    client_id: env.GOOGLE_CLIENT_ID,
    redirect_uri: `${origin}/api/auth/callback`,
    response_type: 'code',
    scope: scopes.join(' '),
    state,
    code_challenge: await challengeFor(verifier),
    code_challenge_method: 'S256',
    access_type: 'offline',
    prompt: 'consent',
  });
  return new Response(null, {
    status: 302,
    headers: {
      Location: page.toString(),
      'Set-Cookie': stateCookie(await seal(env, { state, verifier })),
      'Cache-Control': 'no-store',
    },
  });
}
