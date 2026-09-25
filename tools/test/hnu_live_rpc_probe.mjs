// Live probe: has the consolidated migration landed on the live database?
// Calls public.assert_handle_new_user_contract() (defined only in
// 20260925120000_handle_new_user_consolidated.sql). If the function is absent
// the live DB predates the consolidated fix; if present, it also returns the
// LIVE handle_new_user / prevent_role_escalation definitions plus the 6-path
// signup sweep result.
//
// Run: node tools/test/hnu_live_rpc_probe.mjs
// Env: SUPABASE_URL / SUPABASE_ANON_KEY

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_ANON_KEY;
if (!url || !key) {
  console.error('SUPABASE_URL / SUPABASE_ANON_KEY missing from environment');
  process.exit(2);
}

const res = await fetch(`${url}/rest/v1/rpc/assert_handle_new_user_contract`, {
  method: 'POST',
  headers: {
    apikey: key,
    Authorization: `Bearer ${key}`,
    'Content-Type': 'application/json',
  },
  body: '{}',
});
const text = await res.text();

// Only a 404 (or a PGRST202 "function ... does not exist" naming OUR rpc)
// means the migration has not been applied. Matching a bare "does not exist"
// anywhere in the body false-positives when a sweep path fails on a missing
// helper, which is how this probe once reported a live migration as absent.
if (res.status === 404) {
  console.log('LIVE STATE: assert_handle_new_user_contract() NOT present (404).');
  console.log('=> the consolidated migration has NOT been applied to the live database yet.');
  process.exit(3);
}
if (!res.ok) {
  console.log(`probe failed: ${res.status} ${text.slice(0, 400)}`);
  process.exit(1);
}

let out;
try {
  out = JSON.parse(text);
} catch {
  console.log(`unparseable response: ${text.slice(0, 600)}`);
  process.exit(1);
}
console.log('all_pass:', out.all_pass);
console.log('trigger:', out.trigger_name);
console.log('\nsweep:');
for (const t of out.sweep ?? []) {
  console.log(`  ${t.pass ? 'PASS' : 'FAIL'} ${t.path} — ${t.detail}`);
}
console.log('\nlive profiles columns:', (out.profiles_columns ?? []).join(', '));
console.log('\n--- live signup-chain guards ---');
for (const [k, v] of Object.entries(out.signup_chain_guards ?? {})) {
  console.log(`\n### ${k}\n${v}`);
}
console.log('\n--- live handle_new_user ---');
console.log(out.function_def ?? '(absent)');
