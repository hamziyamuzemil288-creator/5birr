// READ-ONLY live probe: does the service-role-only trust RPC actually have
// its REVOKE applied on the live database?
//
// trust_staff_gateway_email() pre-authorises an address past the signup OTP
// gate. Its domain restriction (checked by sweep path G) is only half the
// control — if the EXECUTE grant leaked to anon or authenticated, any client
// could call it directly and the restriction would be the only thing
// standing between them and a bypass. A migration that says REVOKE is not
// evidence that the REVOKE applied, so assert the live ACL instead.
//
// Run: node tools/test/live_trust_grant_probe.mjs
// Env: SUPABASE_URL / SUPABASE_ANON_KEY (anon is enough — that is the point).

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_ANON_KEY;
if (!url || !key) {
  console.error('SUPABASE_URL / SUPABASE_ANON_KEY missing from environment');
  process.exit(2);
}

const anonHeaders = {
  apikey: key,
  Authorization: `Bearer ${key}`,
  'Content-Type': 'application/json',
};

// 1. Existence + definition, via the already-granted contract probe.
const contract = await fetch(`${url}/rest/v1/rpc/assert_handle_new_user_contract`, {
  method: 'POST',
  headers: anonHeaders,
  body: '{}',
});
if (!contract.ok) {
  console.error(`contract probe failed: ${contract.status} ${(await contract.text()).slice(0, 200)}`);
  process.exit(1);
}
const c = await contract.json();
console.log('companion_functions:', JSON.stringify(c.companion_functions ?? {}, null, 2));
const exists = c.companion_functions?.trust_staff_gateway_email;
console.log(`\ntrust_staff_gateway_email present live: ${exists === true ? 'YES' : 'NO'}`);

// 2. The ACL itself: can an ANON key actually execute it? A 401/403 or
//    "permission denied" is the correct, safe outcome. A 200 would mean the
//    REVOKE never applied and any client could mint a bypass.
console.log('\n--- anon execution attempt (must be refused) ---');
for (const email of ['anon-probe@staff-gateway.invalid', 'anon-probe@real-domain.com']) {
  const res = await fetch(`${url}/rest/v1/rpc/trust_staff_gateway_email`, {
    method: 'POST',
    headers: anonHeaders,
    body: JSON.stringify({ p_email: email }),
  });
  const body = await res.text();
  const refused = res.status === 401 || res.status === 403 || /permission denied/i.test(body);
  console.log(
    `${refused ? 'REFUSED (correct)' : 'EXECUTED (!!)'}  ${email}  ->  ${res.status} ${body.slice(0, 160)}`
  );
}
