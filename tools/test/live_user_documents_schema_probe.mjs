// READ-ONLY live probe: reproduce the EXACT query ProviderDocGate.checkStatus
// makes, and report whether it errors.
//
// The app does:
//   .from('user_documents')
//   .select('document_type, verification_status')
//   .eq('user_id', uid)
//
// If `verification_status` does not exist on the live table, PostgREST
// rejects the whole request (PGRST204) BEFORE RLS is evaluated. The client
// throws, and ProviderDocGate.checkStatus catches it and returns
// DocCheckStatus.checkFailed — which isSatisfied() maps to "satisfied" by
// design (fail open, so a network blip cannot lock a provider out).
//
// The visible consequence is exactly the reported bug: every account is told
// "Account verified" before uploading anything, because the query has never
// once succeeded.
//
// Both column names are probed so a rename or a missing migration is
// distinguishable from a working table with no rows.
//
// Run: node tools/test/live_user_documents_schema_probe.mjs
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

const NUL = '00000000-0000-0000-0000-000000000000';

async function probe(label, select) {
  const res = await fetch(
    `${url}/rest/v1/user_documents?select=${encodeURIComponent(select)}&user_id=eq.${NUL}&limit=1`,
    { headers },
  );
  const text = await res.text();
  let kind;
  if (res.ok) kind = 'OK (schema accepted the column)';
  else if (/PGRST204|Could not find/i.test(text)) kind = 'MISSING COLUMN';
  else if (res.status === 401 || res.status === 403) kind = 'REFUSED (auth/RLS)';
  else kind = `ERROR ${res.status}`;
  console.log(`${label}\n  -> ${res.status} ${kind}\n     ${text.slice(0, 220)}`);
  return kind;
}

console.log('=== the exact projection the app sends ===\n');
const appKind = await probe(
  "select('document_type, verification_status')  <- ProviderDocGate",
  'document_type,verification_status',
);

console.log('=== control: a column known to exist ===\n');
await probe("select('document_type')  <- control", 'document_type');

console.log('=== interpretation ===');
if (String(appKind).startsWith('MISSING COLUMN')) {
  console.log(
    '  ROOT CAUSE: user_documents.verification_status does not exist on the\n' +
    '  live database. Every checkStatus() call throws, checkFailed is\n' +
    '  returned, and isSatisfied() fails OPEN to "satisfied" — so the app\n' +
    '  reports "Account verified" for every account, always.\n' +
    '  The gate has therefore never actually gated anything.',
  );
} else {
  console.log(
    '  The column exists, so the schema is not the cause. The query either\n' +
    '  succeeds or fails for another reason (RLS, network) — the next step\n' +
    '  is to see which, and whether any rows exist at all.',
  );
}
