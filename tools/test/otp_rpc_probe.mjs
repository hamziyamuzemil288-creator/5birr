// One-off diagnostic: does request_email_otp itself fail?
// Anon call is expected to be refused (service_role only) — that distinction
// tells us whether the 500 comes from the RPC or from elsewhere.
const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_ANON_KEY;
const res = await fetch(`${url}/rest/v1/rpc/request_email_otp`, {
  method: 'POST',
  headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ p_email: 'alioballinone@gmail.com', p_code: '123456' }),
});
console.log('anon direct RPC status:', res.status, (await res.text()).slice(0, 240));
