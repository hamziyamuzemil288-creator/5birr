// Decisive check for the Google regression, using GoTrue's PUBLIC settings
// endpoint (anon key is enough, no service role required).
//
// mailer_autoconfirm mirrors the dashboard's "Confirm email" toggle:
//   true  -> GoTrue sets email_confirmed_at at INSERT time, so an OAuth
//            subject would satisfy handle_new_user's provider clause.
//   false -> a new OAuth user is inserted UNCONFIRMED, so
//            email_confirmed_at IS NULL and the provider clause in the
//            signup gate can never match. That is exactly the reported
//            "Database error saving new user" on Google sign-in.
//
// Run: node tools/test/live_autoconfirm_probe.mjs
const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_ANON_KEY;
const res = await fetch(`${url}/auth/v1/settings`, {
  headers: { apikey: key, Authorization: `Bearer ${key}` },
});
console.log('status', res.status);
const s = await res.json();
console.log('mailer_autoconfirm :', s.mailer_autoconfirm);
console.log('phone_autoconfirm  :', s.phone_autoconfirm);
console.log('external.email     :', JSON.stringify(s.external?.email ?? {}));
console.log('external.google    :', JSON.stringify(s.external?.google ?? {}));
console.log('\nverdict: OAuth users are inserted with email_confirmed_at =',
  s.mailer_autoconfirm ? 'SET (gate would pass)' : 'NULL (gate rejects them)');
