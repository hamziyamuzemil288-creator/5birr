// Raw diagnostic for the live contract RPC: prints the exact HTTP status and
// body so a PostgREST schema-cache lag can be told apart from a migration that
// never applied.
const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_ANON_KEY;
const res = await fetch(`${url}/rest/v1/rpc/assert_handle_new_user_contract`, {
  method: 'POST',
  headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
  body: '{}',
});
console.log('status', res.status);
console.log((await res.text()).slice(0, 800));
