// The web version's sign-in functions, with Google faked:
//   node --test test/web/
import assert from 'node:assert/strict';
import { afterEach, test } from 'node:test';

import { onRequestGet as callback } from '../../functions/api/auth/callback.js';
import { onRequestGet as start } from '../../functions/api/auth/start.js';
import { onRequestGet as session } from '../../functions/api/session.js';
import { onRequestPost as signout } from '../../functions/api/signout.js';
import { onRequestPost as token } from '../../functions/api/token.js';
import { seal, sessionCookie } from '../../functions/_session.js';

const env = { GOOGLE_CLIENT_ID: 'id', GOOGLE_CLIENT_SECRET: 'secret', COOKIE_KEY: 'a test key' };
const origin = 'https://eclipse.example';
const realFetch = globalThis.fetch;
afterEach(() => (globalThis.fetch = realFetch));

const idToken = (claims) => `x.${Buffer.from(JSON.stringify(claims)).toString('base64url')}.y`;
const nameValue = (setCookie) => setCookie.split(';')[0];
const request = (path, init = {}) => new Request(`${origin}${path}`, init);

async function signedIn() {
  const sealed = await seal(env, { refresh: 'r1', email: 'a@b.c', id: '42', journalAccess: true });
  return nameValue(sessionCookie(sealed));
}

async function begin() {
  const reply = await start({ request: request('/api/auth/start'), env });
  assert.equal(reply.status, 302);
  const page = new URL(reply.headers.get('Location'));
  assert.equal(page.host, 'accounts.google.com');
  assert.equal(page.searchParams.get('redirect_uri'), `${origin}/api/auth/callback`);
  assert.equal(page.searchParams.get('access_type'), 'offline');
  return { state: page.searchParams.get('state'), cookie: nameValue(reply.headers.get('Set-Cookie')) };
}

test('signing in seals the lasting sign-in into a cookie the page can’t read', async () => {
  const { state, cookie } = await begin();
  let sent;
  globalThis.fetch = async (_, init) => {
    sent = init.body;
    return Response.json({
      refresh_token: 'lasting',
      id_token: idToken({ email: 'a@b.c', sub: '42' }),
      scope: 'openid https://www.googleapis.com/auth/drive.appdata https://www.googleapis.com/auth/drive.file',
    });
  };
  const reply = await callback({
    request: request(`/api/auth/callback?code=c&state=${state}`, { headers: { Cookie: cookie } }),
    env,
  });
  assert.equal(reply.status, 302);
  assert.equal(reply.headers.get('Location'), '/');
  assert.equal(sent.get('client_secret'), 'secret');
  assert.ok(sent.get('code_verifier'));
  const set = reply.headers.getSetCookie().find((c) => c.startsWith('eclipse_session='));
  assert.match(set, /HttpOnly/);
  assert.match(set, /Secure/);
  assert.match(set, /SameSite=Lax/);
  assert.ok(!set.includes('lasting'));

  const who = await session({ request: request('/api/session', { headers: { Cookie: nameValue(set) } }), env });
  assert.deepEqual(await who.json(), { email: 'a@b.c', id: '42', journalAccess: true });
});

test('a sign-in this browser didn’t start is refused', async () => {
  const { cookie } = await begin();
  globalThis.fetch = () => assert.fail('must not reach Google');
  const reply = await callback({
    request: request('/api/auth/callback?code=c&state=other', { headers: { Cookie: cookie } }),
    env,
  });
  assert.equal(reply.headers.get('Location'), '/welcome.html?error=expired');
});

test('saying no to Drive’s hidden folder doesn’t sign in', async () => {
  const { state, cookie } = await begin();
  globalThis.fetch = async () =>
    Response.json({ refresh_token: 'r', id_token: idToken({ email: 'a@b.c', sub: '1' }), scope: 'openid email' });
  const reply = await callback({
    request: request(`/api/auth/callback?code=c&state=${state}`, { headers: { Cookie: cookie } }),
    env,
  });
  assert.equal(reply.headers.get('Location'), '/welcome.html?error=drive');
});

test('no session, or a tampered one, is signed out', async () => {
  assert.equal((await session({ request: request('/api/session'), env })).status, 401);
  const reply = await session({
    request: request('/api/session', { headers: { Cookie: 'eclipse_session=aaaa.bbbb' } }),
    env,
  });
  assert.equal(reply.status, 401);
});

test('access comes only for Eclipse’s own pages, and never shows the lasting sign-in', async () => {
  const Cookie = await signedIn();
  globalThis.fetch = async (_, init) => {
    assert.equal(init.body.get('refresh_token'), 'r1');
    return Response.json({ access_token: 'hour', expires_in: 3599 });
  };
  const elsewhere = await token({
    request: request('/api/token', { method: 'POST', headers: { Cookie, Origin: 'https://evil.example' } }),
    env,
  });
  assert.equal(elsewhere.status, 403);
  const reply = await token({
    request: request('/api/token', { method: 'POST', headers: { Cookie, Origin: origin } }),
    env,
  });
  assert.deepEqual(await reply.json(), { access_token: 'hour', expires_in: 3599 });
  assert.equal(reply.headers.get('Cache-Control'), 'no-store');
});

test('a sign-in Google took back signs out', async () => {
  const Cookie = await signedIn();
  globalThis.fetch = async () => Response.json({ error: 'invalid_grant' }, { status: 400 });
  const reply = await token({
    request: request('/api/token', { method: 'POST', headers: { Cookie, Origin: origin } }),
    env,
  });
  assert.equal(reply.status, 401);
  assert.match(reply.headers.get('Set-Cookie'), /Max-Age=0/);
});

test('Google being unreachable isn’t signing out', async () => {
  const Cookie = await signedIn();
  globalThis.fetch = async () => {
    throw new Error('down');
  };
  const reply = await token({
    request: request('/api/token', { method: 'POST', headers: { Cookie, Origin: origin } }),
    env,
  });
  assert.equal(reply.status, 502);
  assert.equal(reply.headers.get('Set-Cookie'), null);
});

test('signing out ends the session, only from Eclipse’s own pages', async () => {
  const away = await signout({ request: request('/api/signout', { method: 'POST', headers: { Origin: 'https://x.y' } }) });
  assert.equal(away.status, 403);
  const reply = await signout({ request: request('/api/signout', { method: 'POST', headers: { Origin: origin } }) });
  assert.match(reply.headers.get('Set-Cookie'), /Max-Age=0/);
});
