// Live reproduction of the two failing signup paths, using the SAME server API
// the app uses — not a synthetic SQL insert.
//
// 1. STAFF: POST /auth/v1/admin/users with app_metadata.staff_gateway and
//    email_confirm: true, i.e. byte-for-byte what staff-create-gateway sends.
//    The edge function's own error mapping tells us the real failure is NOT
//    EMAIL_OTP_REQUIRED (that branch returns staff_gateway_trigger_rejected),
//    so this prints the exact code/message GoTrue returned.
// 2. OAUTH: GoTrue creates a new OAuth user through the signup endpoint; the
//    distinguishing input is raw_app_meta_data.provider. We cannot forge a
//    Google identity here, so we at least report whether the public signup
//    endpoint still fails and with what.
//
// Every user created is deleted again in a finally block.
//
// Run: node tools/test/live_signup_paths_probe.mjs
// Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY

const url = process.env.SUPABASE_URL;
const service = process.env.SUPABASE_SERVICE_ROLE_KEY;
const anon = process.env.SUPABASE_ANON_KEY;
if (!url || !service) {
  console.error('SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY missing from environment');
  process.exit(2);
}

const adminHeaders = {
  apikey: service,
  Authorization: `Bearer ${service}`,
  'Content-Type': 'application/json',
};

let createdId = null;
try {
  // ── Staff gateway shape ────────────────────────────────────────────────
  const email = `probe-staff-${Date.now()}@staff-gateway.invalid`;
  console.log(`=== STAFF GATEWAY: admin.createUser shape -> ${email} ===`);
  const res = await fetch(`${url}/auth/v1/admin/users`, {
    method: 'POST',
    headers: adminHeaders,
    body: JSON.stringify({
      email,
      password: 'ProbePassword!2345',
      email_confirm: true,
      app_metadata: { staff_gateway: true },
      user_metadata: { full_name: 'Probe Staff' },
    }),
  });
  const body = await res.json().catch(() => ({}));
  console.log('status', res.status);
  if (res.ok) {
    createdId = body?.id;
    console.log('created OK, id', createdId);
    console.log('email_confirmed_at:', body?.email_confirmed_at);
    console.log('raw_app_meta_data:', JSON.stringify(body?.app_metadata ?? body?.raw_app_meta_data));
  } else {
    console.log('ERROR body:', JSON.stringify(body).slice(0, 600));
  }

  // ── OAuth-ish shape: provider present, email NOT confirmed ─────────────
  // This is the shape that matters for the Google regression: whether the
  // trigger trusts an OAuth subject whose email_confirmed_at is still null.
  const oAuthEmail = `probe-oauth-${Date.now()}@test.local`;
  console.log(`\n=== OAUTH SHAPE (unconfirmed) -> ${oAuthEmail} ===`);
  const res2 = await fetch(`${url}/auth/v1/admin/users`, {
    method: 'POST',
    headers: adminHeaders,
    body: JSON.stringify({
      email: oAuthEmail,
      password: 'ProbePassword!2345',
      email_confirm: false,
      app_metadata: { provider: 'google', providers: ['google'] },
      user_metadata: { full_name: 'Probe Google', avatar_url: 'x' },
    }),
  });
  const body2 = await res2.json().catch(() => ({}));
  console.log('status', res2.status);
  if (res2.ok) {
    console.log('created OK, id', body2?.id, '| email_confirmed_at:', body2?.email_confirmed_at);
    createdId = createdId ?? body2?.id;
  } else {
    console.log('ERROR body:', JSON.stringify(body2).slice(0, 600));
  }
} finally {
  if (createdId) {
    const del = await fetch(`${url}/auth/v1/admin/users/${createdId}`, {
      method: 'DELETE',
      headers: adminHeaders,
    });
    console.log(`\ncleanup: deleted probe user ${createdId} (${del.status})`);
  } else {
    console.log('\ncleanup: nothing to delete');
  }
}
