// Live signup-chain contract probe for the handle_new_user investigation.
// READ-ONLY: only GETs the PostgREST OpenAPI spec; writes nothing.
//
// Why: the evolution replay proved the consolidated handle_new_user body is
// correct against the stub schema, so if live signups still fail the
// difference must be live state the stubs approximate. The failing paths
// (staff-gateway, Google OAuth) are exactly the ones whose user_metadata has
// NO city/kebele/street_road — the columns 20260923 added and the trigger
// inserts. If those ALTERs never landed live, ONLY the city-less paths die
// while normal email signups (which pass all fields) keep working — the
// observed symptom pair. RLS hides rows but not schema, so the OpenAPI
// definitions expose the true live column list to anon.
//
// Run: node tools/test/hnu_live_contract_probe.mjs
// Env: SUPABASE_URL / SUPABASE_ANON_KEY (anon is enough).

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_ANON_KEY;
if (!url || !key) {
  console.error('SUPABASE_URL / SUPABASE_ANON_KEY missing from environment');
  process.exit(2);
}

const EXPECTED_PROFILES = ['id', 'full_name', 'phone', 'email', 'national_id', 'status', 'city', 'kebele', 'street_road'];
const EXPECTED_PROVIDER = ['user_id', 'provider_type', 'business_name', 'status', 'city', 'kebele', 'street_road', 'referral_code', 'referred_by_staff_id', 'referred_by_name'];

const res = await fetch(`${url}/rest/v1/`, { headers: { apikey: key, Authorization: `Bearer ${key}` } });
if (!res.ok) {
  console.error(`openapi spec fetch failed: ${res.status} ${await res.text().then((t) => t.slice(0, 200))}`);
  process.exit(1);
}
const spec = await res.json();

function checkColumns(table, expected) {
  const props = spec?.definitions?.[table]?.properties;
  if (!props) {
    console.log(`${table}: NOT EXPOSED to anon (table missing or not in API exposure)`);
    return;
  }
  const live = Object.keys(props);
  const missing = expected.filter((c) => !live.includes(c));
  console.log(`${table}: ${live.length} live columns`);
  console.log(`  columns: ${live.sort().join(', ')}`);
  console.log(missing.length === 0
    ? `  all trigger-referenced columns present (${expected.join(', ')})`
    : `  MISSING LIVE COLUMNS: ${missing.join(', ')}  <- handle_new_user INSERTs would fail with 42703`);
}

console.log('=== live profiles / provider_profiles columns (PostgREST spec) ===');
checkColumns('profiles', EXPECTED_PROFILES);
checkColumns('provider_profiles', EXPECTED_PROVIDER);

// The exact failing-path shapes for reference:
console.log('\nreference: staff-gateway auth user  -> user_metadata { full_name } only');
console.log('reference: Google OAuth auth user   -> user_metadata { full_name, avatar_url } only');
console.log('reference: working email signup     -> user_metadata { full_name, phone, city, ... }');
