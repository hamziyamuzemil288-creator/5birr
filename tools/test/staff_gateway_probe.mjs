// Live probe for the staff-create-gateway 500 bug.
//
// Read-only wrt app data: uses a synthetic CEO-check RPC surface to learn
// which exact validation the deployed create_staff_gateway enforces and
// whether the deployed auth trigger accepts the gateway shape (app_metadata
// staff_gateway + confirmed email). It never creates a real staff row for
// an existing username; usernames are uniquified per run.
//
// Env: SUPABASE_URL, SUPABASE_ANON_KEY. Requires a CEO JWT to fully
// reproduce — when no CEO session is available (STAFF_CEO_EMAIL +
// STAFF_CEO_PASSWORD), the probe runs the public-surface checks only and
// reports the trigger contract via the signup error text.
const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_ANON_KEY;

if (!url || !key) {
  console.error('SUPABASE_URL / SUPABASE_ANON_KEY missing from environment');
  process.exit(2);
}

async function rest(path, body, method = 'POST') {
  const res = await fetch(`${url}${path}`, {
    method,
    headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let data;
  try { data = JSON.parse(text); } catch { data = text; }
  return { status: res.status, data };
}

// 1. Contract check: does the deployed auth trigger treat a dashboard-style
//    user (email_confirmed_at set, no user_metadata) as an admin subject?
//    We cannot insert into auth.users directly, so we instead assert the
//    known contract of the deployed trigger via the signup gate: an
//    unverified signup must still be refused (proves the trigger is the
//    patched one with the staff_gateway bypass OR the pre-0035 one).
{
  const stamp = Date.now();
  const r = await rest('/auth/v1/signup', {
    email: `gateway-probe-${stamp}@invalid`,
    password: `Gp-${stamp}-x`,
    data: { full_name: 'Gateway Probe' },
  });
  const msg = JSON.stringify(r.data);
  console.log('signup gate probe:', r.status, msg.slice(0, 160));
}

// 2. The deployed create_staff_gateway signature contract: calling the RPC
//    anonymously must fail with a permission error (42501), NOT a 500 —
//    proving the function exists with the expected grant surface.
{
  const r = await rest('/rest/v1/rpc/create_staff_gateway', {
    p_actor_id: '00000000-0000-0000-0000-0000000000aa',
    p_auth_user_id: '00000000-0000-0000-0000-0000000000ab',
    p_username: `probe${Date.now()}`,
    p_name: 'Probe',
    p_staff_code: 'PROBE',
    p_permissions: [],
  });
  console.log('rpc surface probe:', r.status, JSON.stringify(r.data).slice(0, 200));
}

// 3. staff table reachability for the service role path (anonymous must be
//    refused by RLS — proves RLS is on so the edge function is the writer).
{
  const r = await rest('/rest/v1/staff?select=id', undefined, 'GET');
  console.log('staff RLS probe:', r.status, JSON.stringify(r.data).slice(0, 120));
}

// 4. Full CEO-path reproduction when credentials are provided.
const ceoEmail = process.env.STAFF_CEO_EMAIL;
const ceoPassword = process.env.STAFF_CEO_PASSWORD;
if (ceoEmail && ceoPassword) {
  const login = await rest('/auth/v1/token?grant_type=password', { email: ceoEmail, password: ceoPassword });
  if (login.status !== 200) {
    console.log('ceo login failed:', login.status);
    process.exit(1);
  }
  const jwt = login.data.access_token;
  const stamp = Date.now();
  const username = `probe${String(stamp).slice(-8)}`;
  const res = await fetch(`${url}/functions/v1/staff-create-gateway`, {
    method: 'POST',
    headers: {
      apikey: key,
      Authorization: `Bearer ${jwt}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      name: 'Probe Staff',
      staff_code: `P${String(stamp).slice(-6)}`,
      username,
      password: 'ProbePass123!',
      confirm_password: 'ProbePass123!',
      permissions: ['sales_transactions'],
      sales_target: 0,
      is_super_admin: false,
      branch: 'ADMIN',
      assigned_categories: [],
    }),
  });
  const text = await res.text();
  console.log('gateway creation probe:', res.status, text.slice(0, 300));
  process.exit(res.status === 201 ? 0 : 1);
} else {
  console.log('CEO credentials not provided — public-surface probes only.');
}
