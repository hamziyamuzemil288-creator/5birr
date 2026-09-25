// Prints only the PROJECT REF (the subdomain of the Supabase URL), which is
// public in every Supabase URL and is not a credential. Used to confirm the
// live probes target the same project the deploy workflow pushes to.
const url = process.env.SUPABASE_URL;
if (!url) {
  console.error('SUPABASE_URL missing');
  process.exit(2);
}
const u = new URL(url);
console.log('probe target project ref:', u.hostname);
console.log('workflow SUPABASE_PROJECT_REF: xnwieehlrhrffoikpglj (deploy-supabase.yml)');
console.log('match:', u.hostname.startsWith('xnwieehlrhrffoikpglj'));
