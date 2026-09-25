// READ-ONLY live probe: is the city filter in the LIVE search_products
// actually doing anything?
//
// 20260925140000_search_geo_scope.sql WAS applied (deploy run 36177921432,
// 19:09:37), and its body filters city-less listings behind
// p_include_global. Yet a previous probe showed 4 rows with city NULL
// returned identically with p_include_global true AND false, which that body
// cannot produce.
//
// This probe isolates the question: pass a city that CANNOT match anything.
// If rows still come back, the city predicate is not being evaluated at all,
// and the live function is not the 0044 body regardless of what the migration
// history claims.
//
// Also prints the actual keys of a returned row, so we can see whether
// distance_km and city are present in the result shape at all.
//
// Run: node tools/test/live_search_body_probe.mjs
// Env: SUPABASE_URL / SUPABASE_ANON_KEY

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_ANON_KEY;
if (!url || !key) {
  console.error('SUPABASE_URL / SUPABASE_ANON_KEY missing from environment');
  process.exit(2);
}

const headers = {
  apikey: key,
  Authorization: `Bearer ${key}`,
  'Content-Type': 'application/json',
};

async function call(label, params) {
  const res = await fetch(`${url}/rest/v1/rpc/search_products`, {
    method: 'POST',
    headers,
    body: JSON.stringify(params),
  });
  const text = await res.text();
  if (!res.ok) {
    console.log(`${label}\n  -> ${res.status} ${text.slice(0, 300)}`);
    return null;
  }
  const rows = JSON.parse(text);
  console.log(`${label}\n  rows=${rows.length}`);
  if (rows.length) {
    console.log(`  keys: ${Object.keys(rows[0]).join(', ')}`);
    const sample = rows[0];
    console.log(
      `  sample: name=${JSON.stringify(sample.name)} city=${JSON.stringify(sample.city)} ` +
      `location=${sample.location === null ? 'null' : 'set'} ` +
      `distance_km=${JSON.stringify(sample.distance_km)}`,
    );
  }
  return rows;
}

const base = {
  p_query: '',
  p_limit: 30,
  p_offset: 0,
  p_lat: 9.032,
  p_lng: 38.7469,
  p_radius_km: 5,
  p_sort_by: 'distance',
};

console.log('=== does p_city filter at all? ===\n');
const realCity = await call('p_city="Addis Ababa"', {
  ...base,
  p_city: 'Addis Ababa',
  p_include_global: false,
});
const bogusCity = await call('p_city="ZZ_NOT_A_REAL_CITY_12345"', {
  ...base,
  p_city: 'ZZ_NOT_A_REAL_CITY_12345',
  p_include_global: false,
});
const nullCity = await call('p_city=null (no filter, documented old behaviour)', {
  ...base,
  p_include_global: false,
});

console.log('\n=== does p_radius_km filter at all? ===\n');
const r0 = await call('p_radius_km=0.5', { ...base, p_city: null, p_radius_km: 0.5 });
const r500 = await call('p_radius_km=500', { ...base, p_city: null, p_radius_km: 500 });

console.log('\n=== interpretation ===');
const bogus = bogusCity?.length ?? -1;
if (bogus > 0) {
  console.log(
    `  A city that cannot exist still returned ${bogus} row(s). The city predicate is\n` +
    '  NOT being evaluated, so the live function is not the 20260925140000 body —\n' +
    '  even though the deploy log says that migration ran.',
  );
} else {
  console.log('  p_city IS filtering, so the 0044 body IS live.');
}
const same = (r0?.length ?? -1) === (r500?.length ?? -1);
console.log(
  same
    ? '  p_radius_km changes nothing (0.5km and 500km return the same count).'
    : `  p_radius_km does change the count (0.5km -> ${r0?.length}, 500km -> ${r500?.length}).`,
);
if (nullCity) {
  console.log(`  p_city=null returns ${nullCity.length} row(s) (documented as "no filter").`);
}
