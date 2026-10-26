// Copy to google_client.dart (which git ignores) and fill in the Desktop
// client from Eclipse's Google Cloud project, Google Auth Platform → Clients.
// A desktop app can't keep a secret, and Google doesn't expect it to: these
// only name the app, and every sign-in still needs the person's own yes in
// the browser. It stays out of the repo so nothing flags it as leaked.
const googleClientId = 'SET-ME.apps.googleusercontent.com';
const googleClientSecret = 'SET-ME';
