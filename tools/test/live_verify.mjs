// Live verification harness — full pass (--full).
// Adds to the anon-surface probes:
//   • a real CAPTCHA solve (request_captcha + verify_captcha)
//   • exactly ONE real OTP email send to OTP_TEST_EMAIL (default
//     alioballinone@gmail.com) — the code is delivered to that mailbox only;
//     it is never requested back from the API and never printed here
//   • 60 s cooldown negative check
//   • verify_email_otp negative probe (wrong code must be rejected)
//   • signup gate probe (unverified signup must be refused)
//   • document self-approval forgery probe (must be rejected)
//   • appeal CAPTCHA trigger probe (must be rejected)
//
// Usage: node tools/test/live_verify.mjs --full
// Env:   SUPABASE_URL, SUPABASE_ANON_KEY, optional OTP_TEST_EMAIL.

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_ANON_KEY;
const testEmail = (process.env.OTP_TEST_EMAIL || 'alioballinone@gmail.com').toLowerCase();
const results = [];
const rec = (name, pass, detail) => {
  results.push({ name, pass, detail });
  console.log(`${pass ? 'ok  ' : 'FAIL'} ${name} — ${detail}`);
};

if (!url || !key) {
  console.error('SUPABASE_URL / SUPABASE_ANON_KEY missing from environment');
  process.exit(2);
}

async function rpc(fn, body = {}) {
  const res = await fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    data = text;
  }
  return { status: res.status, data };
}

async function edge(fn, body) {
  const res = await fetch(`${url}/functions/v1/${fn}`, {
    method: 'POST',
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    data = text;
  }
  return { status: res.status, data };
}

// ------------------------------------------------- view PII re-check (hardened)
{
  const res = await fetch(`${url}/rest/v1/public_provider_profiles?select=*`, {
    headers: { apikey: key, Authorization: `Bearer ${key}` },
  });
  const text = await res.text();
  const forbidden = [
    'owner_national_id', 'national_id', 'user_id', 'owner_name',
    'kebele', 'street_road', 'business_address',
  ];
  const leaked = forbidden.filter((c) => text.includes(c));
  rec(
    'security: public view PII gone after redeploy',
    res.status === 200 && leaked.length === 0,
    `HTTP ${res.status}${leaked.length ? ' LEAKED: ' + leaked.join(',') : ' no restricted columns'}`,
  );
}

// ------------------------------------------------------ real CAPTCHA solve
console.log(`\n[otp] requesting CAPTCHA and sending ONE OTP email to ${testEmail}`);
let solvedId = null;
{
  const r = await rpc('request_captcha');
  const challenge = Array.isArray(r.data) ? r.data[0] : r.data;
  const okReq = r.status === 200 && challenge?.captcha_id;
  rec('captcha: request_captcha issues challenge', okReq,
    `HTTP ${r.status} ${okReq ? `question: ${challenge.question}` : JSON.stringify(r.data)}`);

  if (okReq) {
    // The answer is never returned by the API — read it from the same public
    // question text ("... solve: 7 + 5") like a human would.
    const m = /solve:\s*(\d+)\s*([+\-])\s*(\d+)/.exec(challenge.question || '');
    if (!m) {
      rec('captcha: question parseable', false, challenge.question);
    } else {
      const a = +m[1], b = +m[3];
      const answer = m[2] === '+' ? a + b : a - b;
      const v = await rpc('verify_captcha', { p_captcha_id: challenge.captcha_id, p_answer: String(answer) });
      const vrow = Array.isArray(v.data) ? v.data[0] : v.data;
      const okVer = vrow?.ok === true;
      rec('captcha: correct solve accepted', okVer, `HTTP ${v.status} ${JSON.stringify(v.data)}`);
      if (okVer) solvedId = challenge.captcha_id;
      else {
        // Burned challenge — nothing else to try this run.
        rec('captcha: solve usable for OTP', false, 'verification failed; skipping OTP send');
      }
    }
  }
}

// ------------------------------------------------------ OTP: real send + cooldown
{
  if (!solvedId) {
    rec('otp: send skipped (no solved challenge)', false, 'captcha step failed');
  } else {
    const r = await edge('send-otp', { email: testEmail, captcha_id: solvedId });
    const body = JSON.stringify(r.data);
    const okSend = r.status === 200 && r.data?.delivered === true && !body.includes('dev_code');
    rec('otp: real send delivered (email in mailbox, no code in API)', okSend,
      `HTTP ${r.status} ${body.slice(0, 140)}`);

    // Cooldown: an immediate second request with a fresh solve must be refused.
    if (okSend) {
      const c2 = await rpc('request_captcha');
      const ch2 = Array.isArray(c2.data) ? c2.data[0] : c2.data;
      const m = /solve:\s*(\d+)\s*([+\-])\s*(\d+)/.exec(ch2?.question || '');
      if (m) {
        const a = +m[1], b = +m[3];
        await rpc('verify_captcha', { p_captcha_id: ch2.captcha_id, p_answer: String(m[2] === '+' ? a + b : a - b) });
        const r2 = await edge('send-otp', { email: testEmail, captcha_id: ch2.captcha_id });
        const body2 = JSON.stringify(r2.data);
        const cooled = r2.data?.delivered === false || /cooldown|retry/i.test(body2) || (r2.data?.ok === false);
        rec('otp: 60 s resend cooldown enforced', cooled,
          `HTTP ${r2.status} ${body2.slice(0, 140)}`);
      }
    }
  }
}

// ------------------------------------------------------ verify negative probe
{
  const r = await rpc('verify_email_otp', { p_email: testEmail, p_code: '000000' });
  const denied = r.status >= 400 || r.data === false || (r.data && r.data.ok === false);
  rec('otp: wrong code rejected at verify gate', denied,
    `HTTP ${r.status} ${JSON.stringify(r.data).slice(0, 120)}`);
}

// ------------------------------------------------------ signup gate probe
{
  const stamp = Date.now();
  const res = await fetch(`${url}/auth/v1/signup`, {
    method: 'POST',
    headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      email: `verify-gate-${stamp}@invalid`,
      password: `Sv-${stamp}-x`,
      data: { full_name: 'Live Verify Gate' },
    }),
  });
  const text = await res.text();
  rec('signup: unverified email signup refused', res.status >= 400,
    `HTTP ${res.status} ${text.slice(0, 140)}`);
}

// ------------------------------------------------------ document forgery probe
{
  // Anonymous insert must be refused outright by RLS — the policy-level half
  // of the forgery fix (the trigger half is covered by the SQL harness).
  const res = await fetch(`${url}/rest/v1/user_documents`, {
    method: 'POST',
    headers: {
      apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json',
      Prefer: 'return=representation',
    },
    body: JSON.stringify({
      user_id: '00000000-0000-0000-0000-0000000000aa',
      document_type: 'NATIONAL_ID',
      storage_path: 'probe/forgery.jpg',
      verification_status: 'AUTO_APPROVED',
    }),
  });
  const text = await res.text();
  rec('documents: anonymous forged insert refused', res.status >= 400,
    `HTTP ${res.status} ${text.slice(0, 140)}`);
}

// ------------------------------------------------------ appeal trigger probe
{
  const res = await fetch(`${url}/rest/v1/appeal_cases`, {
    method: 'POST',
    headers: {
      apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      user_id: '00000000-0000-0000-0000-0000000000aa',
      photo_path: 'probe/nope.jpg',
      description: 'live verify probe — no captcha',
    }),
  });
  const text = await res.text();
  rec('appeals: anonymous insert refused (RLS + trigger gate)', res.status >= 400,
    `HTTP ${res.status} ${text.slice(0, 140)}`);
}

console.log('---SUMMARY---');
console.log(JSON.stringify(results));
process.exit(results.every((r) => r.pass) ? 0 : 1);
