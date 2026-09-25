// Leak-or-verify the live project's Site URL WITHOUT dashboard access.
//
// GoTrue's /auth/v1/verify endpoint (magic-link / OTP confirm) and
// /auth/v1/callback respond to bad tokens with a 302 whose Location is
// built from the project's configured redirect target: an explicitly
// passed redirect_to if it is allow-listed, otherwise the project Site
// URL. Hitting them with garbage inputs therefore REVEALS the
// currently-effective fallback URL:
//   - Location starting https://...  => that host is the effective
//     Site URL / allowed fallback (if it is a github URL, root cause CONFIRMED)
//   - Location starting a custom scheme (io.supabase...) => the deep link IS
//     the effective fallback — the dashboard fix landed. GoTrue still appends
//     #error=... / ?error=... query/fragment params to it; that is expected
//     (the app's deep-link handler reads the error, shows the message, and
//     the user just taps Continue with Google again) and does NOT mean the
//     redirect itself is wrong — the target host/scheme is what we assert on.
// Read-only, no secrets printed.
const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_ANON_KEY;
if (!url || !key) { console.error('env missing'); process.exit(2); }

async function show(name, path) {
  const res = await fetch(`${url}${path}`, {
    headers: { apikey: key },
    redirect: 'manual',
  });
  const loc = res.headers.get('location') ?? '(no location)';
  let verdict = '';
  if (loc.includes('github.com')) verdict = '  <<<< GITHUB URL — root cause confirmed (fix NOT applied)';
  else if (/^[a-z][a-z0-9+.-]*:\/\//i.test(loc) && !/^https?:/i.test(loc))
    verdict = '  <<<< CUSTOM SCHEME = effective fallback — dashboard fix IS applied (error params appended by GoTrue are expected)';
  else if (loc.includes('supabase.co')) verdict = '  <<<< self-redirect (error page) — inconclusive';
  else if (loc.startsWith('https://') || loc.startsWith('http://')) verdict = '  <<<< external site is the fallback';
  console.log(`\n[${name}] status=${res.status}\n  ${loc}${verdict}`);
}

// 1. verify with a garbage token (OTP/magic-link confirm path)
await show('verify bad token', '/auth/v1/verify?token=deadbeef&type=signup');
// 2. verify with garbage token + the app deep link as redirect_to
await show(
  'verify bad token + deep link',
  `/auth/v1/verify?token=deadbeef&type=signup&redirect_to=${encodeURIComponent('io.supabase.com.amistbirr.myapp://login-callback/')}`,
);
// 3. callback with a garbage state (the exact post-consent endpoint)
await show('callback bad state', '/auth/v1/callback?state=deadbeef&code=deadbeef');
