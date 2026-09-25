// Post-consent redirect analysis: the account picker appearing proves the
// authorize hop is fine, so the GitHub page must come from what GoTrue's
// /auth/v1/callback redirects to AFTER exchanging the Google code. GoTrue's
// rule there: use the state's redirect_to if it is in the project's allowed
// redirect URLs (Site URL + additional), otherwise silently fall back to the
// project Site URL. We cannot complete a real Google consent here, but we can
// (1) dump the FULL untruncated authorize Location to show exactly what is
// carried in state, and (2) confirm the authorize hop does not reject a
// github.com redirect_to the same way it did not reject evil.example.com —
// proving allow-list enforcement (or fallback) happens at the callback step,
// i.e. exactly where the user's GitHub page appears.
const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_ANON_KEY;
if (!url || !key) { console.error('env missing'); process.exit(2); }

async function hop(provider, redirectTo) {
  let target = `${url}/auth/v1/authorize?provider=${provider}`;
  if (redirectTo) target += `&redirect_to=${encodeURIComponent(redirectTo)}`;
  const res = await fetch(target, { headers: { apikey: key }, redirect: 'manual' });
  const loc = res.headers.get('location') ?? '(none)';
  console.log(`\nauthorize provider=${provider} redirect_to=${redirectTo ?? '(none)'}`);
  console.log(`status=${res.status}`);
  console.log(`FULL location:\n${loc}\n`);
  if (redirectTo) {
    console.log(`redirect_to echoed into the provider URL: ${loc.includes(encodeURIComponent(redirectTo.split('://')[0]))}`);
  }
}

// 1. The app's exact flow — full header this time.
await hop('google', 'io.supabase.com.amistbirr.myapp://login-callback/');
// 2. Control: a github.com redirect_to — accepted at authorize?
await hop('google', 'https://github.com/mededfami127-web/5birr-1');
