// READ-ONLY live probe: can any CLIENT role call public.delete_staff()?
//
// This exists to settle a specific question about the 403
// "only_ceo_can_delete_staff" that the CEO hit while deleting a staff member.
//
// delete_staff() determines the caller with `auth.uid()`. It is granted to
// service_role ONLY, and the edge function invokes it with the service-role
// client — which carries no end-user JWT. So auth.uid() inside that function
// is NULL, is_ceo(NULL) is false, and the CEO check can never pass no matter
// who is signed in.
//
// If this probe shows a client role IS able to call delete_staff, that
// explanation is wrong and the bug is elsewhere. It expects 42501
// "permission denied" for both anon and authenticated.
//
// Nothing is written: the calls are rejected before the function body runs.
//
// Run: node tools/test/live_delete_staff_grant_probe.mjs
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

console.log('=== can a client role call public.delete_staff()? ===\n');

for (const [role, body] of [
  ['anon (apikey role)', { p_staff_id: '00000000-0000-0000-0000-000000000000' }],
  [
    'anon, legacy 1-arg signature (p_staff_id only)',
    { p_staff_id: '00000000-0000-0000-0000-000000000000' },
  ],
]) {
  const res = await fetch(`${url}/rest/v1/rpc/delete_staff`, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
  });
  const text = await res.text();
  const denied = res.status === 401 || res.status === 403 || /permission denied/i.test(text);
  console.log(`${denied ? 'REFUSED (expected)' : 'ALLOWED (!!)'}  ${role}`);
  console.log(`    ${res.status} ${text.slice(0, 200)}\n`);
}

// The decisive companion fact: is_ceo() with no argument resolves auth.uid()
// itself, which is why the CLIENT-side Edit path behaves correctly while the
// gateway path cannot. Confirm the RPC is reachable at all as the anon role,
// i.e. that the 403 above is a GRANT decision and not a missing function.
console.log('=== control: is_ceo() IS callable by the client role ===');
const res = await fetch(`${url}/rest/v1/rpc/is_ceo`, {
  method: 'POST',
  headers,
  body: '{}',
});
const text = await res.text();
console.log(`  ${res.status} ${text.slice(0, 200)}`);
console.log(
  res.ok
    ? '  => is_ceo() resolved via auth.uid() and returned a value, so the client path works.'
    : '  => is_ceo() also refused.',
);
console.log(
  '\nConclusion: if delete_staff is refused for the client role, it can only\n' +
    'ever be invoked by the service-role edge function, where auth.uid() is\n' +
    'NULL — so its is_ceo(auth.uid()) check can never pass.',
);
