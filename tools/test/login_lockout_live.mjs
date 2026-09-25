// Live proof of the Task 13 item 2 lockout against the deployed project.
// Writes ONLY synthetic-key rows to login_attempts (no real account is
// involved; rows self-prune after 7 days) and finishes by recording a
// success, which clears the window it created — so it leaves no lockout
// behind for any key.
//
// The gate enforces the CAPTCHA before it checks the lockout, so every gate
// call below carries a freshly solved challenge — the same tick+math flow the
// login screen performs, meaning this exercises the real client path.
const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_ANON_KEY;
const probeEmail = 'lockout-probe@invalid.example';

const results = [];
const rec = (name, pass, detail) => {
  results.push({ name, pass, detail });
  console.log(`${pass ? 'ok  ' : 'FAIL'} ${name} — ${detail}`);
};

async function rpc(fn, body = {}) {
  const res = await fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  let data;
  try { data = JSON.parse(await res.text()); } catch { data = await res.text(); }
  return { status: res.status, data };
}

async function gate(captchaId) {
  const res = await fetch(`${url}/functions/v1/login-gate`, {
    method: 'POST',
    headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ action: 'gate', email: probeEmail, captcha_id: captchaId }),
  });
  let data;
  try { data = JSON.parse(await res.text()); } catch { data = await res.text(); }
  return { status: res.status, data };
}

async function record(success) {
  const res = await fetch(`${url}/functions/v1/login-gate`, {
    method: 'POST',
    headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ action: 'record', email: probeEmail, success }),
  });
  return res.status;
}

// Real CAPTCHA solve, exactly like the login screen does.
async function solvedChallenge() {
  const req = await rpc('request_captcha');
  const challenge = Array.isArray(req.data) ? req.data[0] : req.data;
  const m = /solve:\s*(\d+)\s*([+\-])\s*(\d+)/.exec(challenge?.question || '');
  if (!m) return null;
  const answer = m[2] === '+' ? Number(m[1]) + Number(m[3]) : Number(m[1]) - Number(m[3]);
  const ver = await rpc('verify_captcha', { p_captcha_id: challenge.captcha_id, p_answer: String(answer) });
  const ok = ver.status === 200 && (ver.data?.[0]?.ok === true || ver.data?.ok === true);
  return ok ? challenge.captcha_id : null;
}

// 1. Baseline: solve A, then request challenge B before A reaches login-gate.
// This reproduces the production race that used to delete A globally.
let captcha = await solvedChallenge();
rec('real CAPTCHA solve for login', captcha !== null, captcha ? 'challenge issued, solved, accepted' : 'solve failed');
const competing = await rpc('request_captcha');
rec('second client can request another CAPTCHA',
  competing.status === 200 && (competing.data?.[0]?.captcha_id || competing.data?.captcha_id),
  `HTTP ${competing.status}`);
let g = await gate(captcha);
rec('solved CAPTCHA survives another client request → gate opens',
  g.status === 200 && g.data?.ok === true && typeof g.data?.failures_remaining === 'number',
  `HTTP ${g.status} ${JSON.stringify(g.data)}`);

// 2. Wrong CAPTCHA must still be refused (server-side enforcement, not cosmetic).
{
  const bad = await gate('00000000-0000-0000-0000-000000000000');
  rec('gate with a bogus CAPTCHA → refused', bad.status === 400 && bad.data?.error === 'captcha_failed',
    `HTTP ${bad.status} ${JSON.stringify(bad.data)}`);
}

// 3. Record 8 failed attempts (the record path runs before the CAPTCHA gate,
//    exactly like the client reporting an Auth failure).
let recorded = 0;
for (let i = 0; i < 8; i++) {
  if ((await record(false)) === 200) recorded++;
}
rec('8 failed attempts recorded via the function', recorded === 8, `${recorded}/8 accepted`);

// 4. Gate must now refuse BEFORE any credential check, with a retry window.
captcha = await solvedChallenge();
g = await gate(captcha);
const locked = g.data?.error === 'temporarily_locked';
rec('gate after 8 failures → temporarily_locked', locked, `HTTP ${g.status} ${JSON.stringify(g.data)}`);
rec('lockout carries a 15-minute retry window',
  locked && g.data?.retry_after_seconds === 900,
  `retry_after_seconds=${g.data?.retry_after_seconds}`);

// 5. A recorded success clears the window (a real user who mistypes once is
//    not punished later).
await record(true);
captcha = await solvedChallenge();
g = await gate(captcha);
rec('gate after a recorded success → unlocked again',
  g.status === 200 && g.data?.ok === true && g.data?.failures_remaining >= 1,
  `HTTP ${g.status} ${JSON.stringify(g.data)}`);

const failed = results.filter((r) => !r.pass).length;
console.log(`\n${failed === 0 ? 'ALL LOGIN-LOCKOUT LIVE CHECKS PASSED' : failed + ' CHECK(S) FAILED'}`);
process.exit(failed === 0 ? 0 : 1);
