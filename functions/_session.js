// Eclipse's sign-in, for the web version. Google gives a lasting sign-in only
// to a server holding the client secret, so these functions do that part. The
// lasting sign-in is sealed with COOKIE_KEY into a cookie the page can't read,
// and nothing is stored here: a person's data goes straight between their
// browser and their own Drive.

export const SESSION_COOKIE = 'eclipse_session';
const STATE_COOKIE = 'eclipse_sign_in';
const SESSION_DAYS = 400; // The longest browsers keep a cookie.

const encoder = new TextEncoder();
const decoder = new TextDecoder();

const base64url = (bytes) =>
  btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

const unbase64url = (text) =>
  Uint8Array.from(atob(text.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0));

const key = async (env) =>
  crypto.subtle.importKey(
    'raw',
    await crypto.subtle.digest('SHA-256', encoder.encode(env.COOKIE_KEY)),
    'AES-GCM',
    false,
    ['encrypt', 'decrypt'],
  );

export async function seal(env, value) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const sealed = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, await key(env), encoder.encode(JSON.stringify(value)));
  return `${base64url(iv)}.${base64url(sealed)}`;
}

export async function unseal(env, text) {
  try {
    const [iv, sealed] = text.split('.');
    const opened = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: unbase64url(iv) }, await key(env), unbase64url(sealed));
    return JSON.parse(decoder.decode(opened));
  } catch {
    return null; // Tampered with, or sealed under an old key: signed out.
  }
}

export function cookies(request) {
  const found = {};
  for (const part of (request.headers.get('Cookie') ?? '').split(';')) {
    const at = part.indexOf('=');
    if (at > 0) found[part.slice(0, at).trim()] = part.slice(at + 1).trim();
  }
  return found;
}

const cookie = (name, value, seconds) =>
  `${name}=${value}; Path=/api; HttpOnly; Secure; SameSite=Lax; Max-Age=${seconds}`;

export const sessionCookie = (value) => cookie(SESSION_COOKIE, value, SESSION_DAYS * 86400);
export const noSessionCookie = () => cookie(SESSION_COOKIE, '', 0);
export const stateCookie = (value) => cookie(STATE_COOKIE, value, 600);
export const noStateCookie = () => cookie(STATE_COOKIE, '', 0);
export const stateFrom = (request) => cookies(request)[STATE_COOKIE];

export const randomText = (bytes) => base64url(crypto.getRandomValues(new Uint8Array(bytes)));

export const challengeFor = async (verifier) =>
  base64url(await crypto.subtle.digest('SHA-256', encoder.encode(verifier)));

/// The account inside an id token, which came straight from Google over TLS.
export function claimsOf(idToken) {
  try {
    return JSON.parse(decoder.decode(unbase64url(idToken.split('.')[1])));
  } catch {
    return {};
  }
}

/// The session a request carries; null if it has none that opens.
export async function sessionOf(request, env) {
  const sealed = cookies(request)[SESSION_COOKIE];
  return sealed ? unseal(env, sealed) : null;
}

/// A page elsewhere posting here would carry the cookie too, so anything that
/// isn't only reading has to come from Eclipse's own pages.
export function fromOurPage(request) {
  return request.headers.get('Origin') === new URL(request.url).origin;
}

export function answer(status, body, headers = {}) {
  return new Response(body === undefined ? null : JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', ...headers },
  });
}
