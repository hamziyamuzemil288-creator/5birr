// Follow-up probe: the settings endpoint says no providers are enabled while
// /authorize?provider=google redirects to Google. Resolve which one lies.
// 1. settings twice (cache?)
// 2. /authorize?provider=github — where does a GitHub authorize go?
// 3. /authorize?provider=nonsense — control (what "disabled" looks like)
const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_ANON_KEY;
if (!url || !key) { console.error('env missing'); process.exit(2); }

for (let i = 1; i <= 2; i++) {
  const r = await fetch(`${url}/auth/v1/settings`, { headers: { apikey: key } });
  const s = await r.json();
  const ext = s?.external ?? {};
  const enabled = Object.entries(ext).filter(([, c]) => c?.enabled).map(([n]) => n);
  console.log(`settings try ${i}: enabled=${JSON.stringify(enabled)} google=${JSON.stringify(ext?.google)}`);
}

async function authorize(provider) {
  const res = await fetch(`${url}/auth/v1/authorize?provider=${provider}`,
    { headers: { apikey: key }, redirect: 'manual' });
  const loc = res.headers.get('location') ?? '(none)';
  console.log(`authorize ${provider}: status=${res.status} -> ${loc.slice(0, 140)}`);
  if (res.status !== 302) {
    const t = await res.text().catch(() => '');
    console.log('  body:', t.slice(0, 200));
  }
}
await authorize('github');
await authorize('definitely_not_a_provider');
