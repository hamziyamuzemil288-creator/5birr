// READ-ONLY live probe: which half of `staff_gateway_setup_failed` is even
// reachable on the live project right now?
//
// staff-create-gateway returns that code from exactly two sites:
//   1. trust_staff_gateway_email() failing        -> migration 20260925150000
//   2. create_staff_gateway() failing unknown-ly   -> migration 20260925170000
//      (notably STAFF_AUTH_IDENTITY_MISMATCH, raised when the SQL-computed
//       synthetic email disagrees with the auth.users row the edge fn made)
//
// PostgREST distinguishes the two failure shapes we care about:
//   404 + "Could not find the function" -> migration NOT applied (missing)
//   401/403 + "permission denied"       -> function EXISTS and is revoked
//                                          from anon (the correct state)
//
// Never writes app data: every RPC below is either revoked from anon
// (refused outright) or a pure computation.
//
// Run: node tools/test/live_staff_setup_probe.mjs
// Env: SUPABASE_URL / SUPABASE_ANON_KEY (loaded from .env.local).
const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_ANON_KEY;
if (!url || !key) {
  console.error('SUPABASE_URL / SUPABASE_ANON_KEY missing');
  process.exit(2);
}
const h = {
  apikey: key,
  Authorization: `Bearer ${key}`,
  'Content-Type': 'application/json',
};

async function probe(fn, body) {
  const r = await fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: h,
    body: JSON.stringify(body),
  });
  const t = await r.text();
  let verdict;
  // NOTE: PGRST202 fires both when the function is absent AND when the
  // argument list does not match (PostgREST then reports the signature it
  // searched for). Every probe below therefore passes the function's REAL
  // parameter names, so a PGRST202 here genuinely means "not created".
  if (r.status === 404 && /could not find the function/i.test(t)) {
    verdict = 'MISSING  -> migration not applied live';
  } else if (/permission denied for function/i.test(t)) {
    verdict = 'PRESENT + revoked from anon  -> migration applied, ACL correct';
  } else {
    verdict = `OTHER (HTTP ${r.status})`;
  }
  console.log(`${fn.padEnd(30)} ${verdict}`);
  console.log(`    ${t.slice(0, 180).replace(/\s+/g, ' ')}`);
}

console.log('--- site 1: trust_staff_gateway_email (20260925150000) ---');
await probe('trust_staff_gateway_email', {
  p_email: 'probe@staff-gateway.invalid',
});

console.log('\n--- site 2: create_staff_gateway identity helpers (20260925170000) ---');
await probe('staff_gateway_email', { p_username: 'probename' });
// Full parameter list so a PGRST202 can only mean "function absent", never
// "argument mismatch" — the earlier empty-body form could not tell them apart.
await probe('create_staff_gateway', {
  p_actor_id: '00000000-0000-0000-0000-000000000001',
  p_auth_user_id: '00000000-0000-0000-0000-000000000002',
  p_username: 'probename',
  p_name: 'Probe Name',
  p_staff_code: 'PROBE-1',
  p_permissions: [],
  p_sales_target: 0,
  p_is_super_admin: false,
  p_branch: 'ADMIN',
  p_assigned_categories: [],
});

console.log('\n--- companion: handle_new_user contract ---');
const c = await fetch(`${url}/rest/v1/rpc/assert_handle_new_user_contract`, {
  method: 'POST',
  headers: h,
  body: '{}',
});
if (c.ok) {
  const j = await c.json();
  console.log('    companion_functions:', JSON.stringify(j.companion_functions ?? {}));
} else {
  console.log(`    contract probe HTTP ${c.status} ${(await c.text()).slice(0, 160)}`);
}
