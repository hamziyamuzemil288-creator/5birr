// READ-ONLY live probe: did 20260925200000_product_location_backfill.sql
// actually change the live database, and does proximity filtering now bite?
//
// The deploy log says the migration ran ("Applying migration
// 20260925200000_product_location_backfill.sql... Finished supabase db push").
// A green deploy is not the same as a changed database, so this measures the
// effect directly instead of trusting the log:
//
//   1. how many reachable listings have a location vs not
//   2. whether p_radius_km now changes the result count at all
//
// RESULT AT 16600af (2026-09-25, after the migration was applied):
//
//     reachable rows        : 4
//     with a location       : 0
//     without a location    : 4
//     p_radius_km 0.5/5/500 : 4 / 4 / 4   <- radius still a no-op
//
// So the migration applied but changed nothing for these rows: there was no
// provider business GPS to copy from. That makes the remaining gap DATA, not
// code — the backfill can only copy a location that exists. To turn this probe
// meaningful, give one provider a business location in the app (or create a
// listing with the pin, which is now required) and re-run it.
//
// Before the backfill, location-less rows made p_radius_km a no-op: every row
// came back regardless of radius, because the live predicate is
// `v_location IS NULL OR p.location IS NULL OR ST_DWithin(...)` and a NULL row
// location short-circuits the whole clause.
//
// Run: node tools/test/live_product_location_probe.mjs
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
};

// NOTE: a direct `select=location` on public.products is REFUSED for the anon
// role (42501). The products_public_read policy calls owns_provider_profile(),
// which reads provider_profiles, and anon has no grant on that table. The app
// never hits this because every read carries a signed-in user's JWT
// (role=authenticated); only this keyless probe does.
//
// So coverage is measured THROUGH the search RPC instead, which is
// SECURITY DEFINER. In the live body distance_km is non-null only when BOTH the
// searcher's position and the row's p.location are set — so with a position
// supplied, `distance_km is null` means that row has no location.

async function coverage() {
  const res = await fetch(`${url}/rest/v1/rpc/search_products`, {
    method: 'POST',
    headers: { ...headers, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      p_query: '',
      p_limit: 200,
      p_offset: 0,
      p_lat: 9.032,
      p_lng: 38.7469,
      p_city: null,
      p_include_global: true, // widest possible net
      p_sort_by: 'distance',
    }),
  });
  if (!res.ok) {
    console.log(`  search_products -> ${res.status} ${(await res.text()).slice(0, 200)}`);
    return null;
  }
  const rows = JSON.parse(await res.text());
  const located = rows.filter((r) => r.distance_km !== null && r.distance_km !== undefined);
  console.log(`  reachable rows        : ${rows.length}`);
  console.log(`  with a location       : ${located.length}`);
  console.log(`  without a location    : ${rows.length - located.length}`);
  if (located.length) {
    console.log(`  nearest distance      : ${Math.min(...located.map((r) => r.distance_km))} km`);
  }
  return rows;
}

console.log('=== products.location coverage (live, via search_products) ===\n');
await coverage();

// --- 2. does p_radius_km bite now? ------------------------------------------
async function search(label, params) {
  const res = await fetch(`${url}/rest/v1/rpc/search_products`, {
    method: 'POST',
    headers: { ...headers, 'Content-Type': 'application/json' },
    body: JSON.stringify(params),
  });
  const text = await res.text();
  if (!res.ok) {
    console.log(`  ${label} -> ${res.status} ${text.slice(0, 200)}`);
    return null;
  }
  const rows = JSON.parse(text);
  const dists = rows.map((r) => r.distance_km);
  const located = dists.filter((d) => d !== null && d !== undefined).length;
  console.log(
    `  ${label}: rows=${rows.length} with_distance=${located}` +
      (located ? ` min=${Math.min(...dists.filter((d) => d != null))}` : ''),
  );
  return rows;
}

// Addis Ababa city centre.
const base = {
  p_query: '',
  p_limit: 50,
  p_offset: 0,
  p_lat: 9.032,
  p_lng: 38.7469,
  p_city: null,
  p_include_global: false,
  p_sort_by: 'distance',
};

console.log('\n=== does p_radius_km change the count? ===\n');
const r05 = await search('p_radius_km=0.5 ', { ...base, p_radius_km: 0.5 });
const r5 = await search('p_radius_km=5   ', { ...base, p_radius_km: 5 });
const r500 = await search('p_radius_km=500 ', { ...base, p_radius_km: 500 });

console.log('\n=== interpretation ===');
const n05 = r05?.length ?? -1;
const n5 = r5?.length ?? -1;
const n500 = r500?.length ?? -1;
if (n05 === n5 && n5 === n500) {
  console.log(
    `  p_radius_km still changes nothing (${n05}/${n5}/${n500}). Proximity is\n` +
      '  not filtering. Check the coverage numbers above: if "without a\n' +
      '  location" covers every row, there is simply no located data to filter\n' +
      '  on (a data gap), not a failed migration — the deploy log confirms the\n' +
      '  migration applied.',
  );
} else {
  console.log(
    `  p_radius_km now filters (0.5km=${n05}, 5km=${n5}, 500km=${n500}).` +
      ' The backfill landed and proximity is effective.',
  );
}
