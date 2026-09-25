// Is staff-create-gateway actually deployed and reachable on the live project?
// A 404 here would mean the Flutter app cannot reach the function at all
// (the "fix never reached the server" scenario). No CEO credentials needed.
const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_ANON_KEY;
if (!url || !key) { console.error('env missing'); process.exit(2); }

const res = await fetch(`${url}/functions/v1/staff-create-gateway`, {
  method: 'POST',
  headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({}),
});
const text = await res.text();
console.log('status:', res.status);
console.log('body:', text.slice(0, 300));
console.log(res.status === 404
  ? '=> FUNCTION NOT DEPLOYED / NOT REACHABLE'
  : '=> function reachable (auth/validation response, not 404)');
