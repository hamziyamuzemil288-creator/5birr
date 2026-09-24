// One-off live probes for the remaining verification pass:
//   • repo-chat: anonymous calls must be refused (function is auth-gated)
//   • staff-login: deployed endpoint must exist and refuse unknown credentials
//     (never leaks whether the account exists vs password wrong in the body)
//   • login-gate: deployed endpoint must exist and answer the gate action
//     (CAPTCHA enforcement + lockout — Task 13 item 2)
const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_ANON_KEY;

async function probe(name, path, body) {
  const res = await fetch(`${url}/functions/v1/${path}`, {
    method: 'POST',
    headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  console.log(`${name}: HTTP ${res.status} ${text.slice(0, 200)}`);
  return res.status;
}

const chat = await probe('repo-chat (anon, must be 401)', 'repo-chat', { message: 'hello' });
console.log(chat === 401 ? 'ok   repo-chat rejects anonymous calls' : 'FAIL repo-chat anon gate');

const staff = await probe('staff-login (unknown user, must be 4xx)', 'staff-login', {
  username: 'definitely-not-a-real-staff-account',
  password: 'wrong-password-probe',
});
console.log(staff >= 400 && staff < 500 ? 'ok   staff-login endpoint live, unknown user refused' : 'FAIL staff-login probe');
// login-gate: the gate for a nonexistent account must still answer sanely.
// With captcha_enforced=true it asks for the challenge (400 captcha_required);
// when the flag is off it lets the attempt through (200 ok) — either way the
// endpoint is LIVE. 404/not-found means the function was not deployed.
const gate = await probe('login-gate (unknown user)', 'login-gate', {
  action: 'gate',
  email: 'probe-not-a-user@example.com',
});
const gateLive = gate === 400 || gate === 200;
console.log(gateLive ? 'ok   login-gate endpoint live' : 'FAIL login-gate not deployed or misbehaving');

process.exit(chat === 401 && staff >= 400 && staff < 500 && gateLive ? 0 : 1);
