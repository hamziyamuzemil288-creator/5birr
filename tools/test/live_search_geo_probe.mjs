// READ-ONLY live probe: is the geo-scope search fix (20260925140000)
// actually deployed, and is p_include_global leaking foreign results?
//
// Two separate questions, both of which have bitten this project before:
//
//   1. Was the fix applied to the LIVE database at all, or does the live
//      function still have the old body (p_include_global declared but never
//      read, p_radius_km ignored)?
//   2. Even with the fix live, the client explicitly sends
//      p_include_global: true, and the fixed body admits every listing with
//      city IS NULL regardless of distance. Those are exactly the
//      "unfamiliar place name" results.
//
// Distinguishes them by A/B-ing the same query with the global tail on vs
// off. If turning it off changes the result set, the global tail is a live
// cause regardless of whether the radius filter is working.
//
// Run: node tools/test/live_search_geo_probe.mjs
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

// Addis Ababa — the app's default city (public.default_city()).
const LAT = 9.0320;
const LNG = 38.7469;

async function search(label, params) {
  const res = await fetch(`${url}/rest/v1/rpc/search_products`, {
    method: 'POST',
    headers,
    body: JSON.stringify(params),
  });
  const text = await res.text();
  if (!res.ok) {
    console.log(`${label}\n  -> ${res.status} ${text.slice(0, 300)}\n`);
    return null;
  }
  const rows = JSON.parse(text);
  const dists = rows
    .map((r) => r.distance_km)
    .filter((d) => typeof d === 'number')
    .sort((a, b) => a - b);
  const cities = [...new Set(rows.map((r) => r.city).filter(Boolean))];
  console.log(`${label}`);
  console.log(`  rows: ${rows.length}`);
  if (dists.length) {
    console.log(`  distance_km: min=${dists[0].toFixed(1)} max=${dists[dists.length - 1].toFixed(1)}`);
  } else {
    console.log('  distance_km: none returned');
  }
  console.log(`  cities in results: ${cities.length ? cities.join(', ') : '(all NULL)'}\n`);
  return { rows, dists, cities };
}

const base = {
  p_query: '',
  p_limit: 30,
  p_offset: 0,
  p_city: 'Addis Ababa',
  p_lat: LAT,
  p_lng: LNG,
  p_radius_km: 5,
  p_sort_by: 'distance',
};

console.log('=== A/B: is the city-less "global" tail leaking in? ===\n');
const withGlobal = await search('A: p_include_global=true  (WHAT THE CLIENT SENDS)', {
  ...base,
  p_include_global: true,
});
const withoutGlobal = await search('B: p_include_global=false (strictly local)', {
  ...base,
  p_include_global: false,
});

console.log('=== is p_radius_km honoured at all? ===\n');
const tight = await search('C: radius 1km, global off', {
  ...base,
  p_radius_km: 1,
  p_include_global: false,
});

console.log('=== interpretation ===');
if (!withGlobal) {
  console.log('  search_products is not callable with the anon key; results above');
  console.log('  are inconclusive. Re-run with an authenticated user JWT.');
} else {
  const extra = withGlobal.rows.length - (withoutGlobal?.rows.length ?? 0);
  if (extra > 0) {
    console.log(`  ${extra} row(s) appear ONLY when p_include_global=true.`);
    console.log('  Those rows bypass the radius filter entirely:');
    console.log('    AND (p.city IS NULL OR p.city = p_city');
    console.log('         OR (p.city IS NULL AND COALESCE(p_include_global, true)))');
    console.log('  A listing with city IS NULL matches on the last clause no matter');
    console.log('  how far away it is. The client sends p_include_global: true, so');
    console.log('  this is a live cause of the "unfamiliar place names".');
  } else {
    console.log('  The global tail is NOT adding rows here, so p_include_global is');
    console.log('  not the current cause.');
  }
  const far = (withGlobal.dists ?? []).filter((d) => d > 5.01);
  if (far.length) {
    console.log(`  BUT ${far.length} row(s) came back beyond the 5km radius, so`);
    console.log('  p_radius_km is NOT being applied to located rows — which points');
    console.log('  at the OLD body still being live (20260925140000 not deployed).');
  } else {
    console.log('  All located rows are within the 5km radius, so p_radius_km IS');
    console.log('  being applied — the geo fix IS live.');
  }
  if (tight) {
    console.log(`  Tightening the radius to 1km changed the count from`);
    console.log(`  ${withoutGlobal?.rows.length} to ${tight.rows.length} — a radius change that`);
    console.log('  has no effect is the signature of an ignored p_radius_km.');
  }
}
