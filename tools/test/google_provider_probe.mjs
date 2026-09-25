// Read-only probe for the "Continue with Google lands on a GitHub page" bug.
//
// 1. Dumps EVERY enabled external.* provider from /auth/v1/settings so a
//    stray GitHub provider is visible.
// 2. Traces the live /auth/v1/authorize?provider=google redirect chain with
//    manual redirect following — prints each hop's Location header. This is
//    exactly the URL Chrome opens when the app taps "Continue with Google",
//    so whatever GitHub-related endpoint appears here is the root cause.
// 3. Checks whether the app's deep-link redirect_to is accepted by the
//    authorize endpoint (disallowed redirect_to => GoTrue falls back to the
//    project's Site URL, which would explain landing on an unrelated page).
//
// No secrets printed. Env: SUPABASE_URL / SUPABASE_ANON_KEY.
const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_ANON_KEY;

if (!url || !key) {
  console.error('SUPABASE_URL / SUPABASE_ANON_KEY missing from environment');
  process.exit(2);
}

const DEEP_LINK = 'io.supabase.com.amistbirr.myapp://login-callback/';

// --- 1. All enabled providers --------------------------------------------
const sres = await fetch(`${url}/auth/v1/settings`, { headers: { apikey: key } });
const settings = await sres.json();
const external = settings?.external ?? {};
console.log('=== enabled external providers ===');
for (const [name, cfg] of Object.entries(external)) {
  if (cfg?.enabled) console.log(`${name}: enabled=${cfg.enabled}`);
}
console.log('github enabled:', external?.github?.enabled ?? false);
console.log('google enabled:', external?.google?.enabled ?? false);
console.log('signup disabled:', settings?.disable_signup);
console.log('mailer autoconfirm:', settings?.mailer_autoconfirm);

// --- 2. Trace the authorize redirect chain (what Chrome actually opens) ---
async function authorizeProbe(label, redirectParam) {
  const target = `${url}/auth/v1/authorize?provider=google${
    redirectParam ? `&redirect_to=${encodeURIComponent(redirectParam)}` : ''
  }`;
  console.log(`\n=== authorize probe: ${label} ===`);
  let res = await fetch(target, { headers: { apikey: key }, redirect: 'manual' });
  for (let hop = 0; hop < 5; hop++) {
    const loc = res.headers.get('location');
    console.log(`hop ${hop + 1}: status=${res.status} location=${loc ? loc.slice(0, 180) : '(none)'}`);
    if (!loc) {
      const text = await res.text().catch(() => '');
      if (text) console.log('  body:', text.slice(0, 200));
      break;
    }
    if (!/^https?:/i.test(loc)) {
      console.log(`  (non-http location — deep link returned to app: ${loc.slice(0, 120)})`);
      break;
    }
    res = await fetch(loc, { redirect: 'manual' }).catch((e) => {
      console.log('  follow failed:', e.message);
      return null;
    });
    if (!res) break;
  }
}

await authorizeProbe('deep-link redirect_to (app flow)', DEEP_LINK);
await authorizeProbe('no redirect_to (falls back to Site URL)', null);

// --- 3. Is a garbage redirect_to rejected? (allow-list sanity) ------------
{
  const target = `${url}/auth/v1/authorize?provider=google&redirect_to=${encodeURIComponent('https://evil.example.com/cb')}`;
  const res = await fetch(target, { headers: { apikey: key }, redirect: 'manual' });
  const loc = res.headers.get('location');
  console.log('\n=== garbage redirect_to control ===');
  console.log(`status=${res.status} location=${loc ? loc.slice(0, 180) : '(none)'}`);
  console.log(loc && /evil\.example/.test(loc)
    ? 'WARNING: arbitrary redirect_to accepted — allow-list not enforced'
    : 'ok: arbitrary redirect_to NOT accepted (allow-list enforced)');
}
