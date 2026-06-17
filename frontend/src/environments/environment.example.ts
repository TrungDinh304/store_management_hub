// TEMPLATE — committed to git. The real `environment.ts` is gitignored.
// Copy this to `environment.ts` and fill in your project's values,
// or just run `npm run setup:env` (also runs automatically on start/build).
//
// SECURITY: only the publishable / anon key belongs here — it is designed to be
// shipped in the browser bundle and is protected by RLS. NEVER place the
// `service_role` key (or any true secret) in a frontend file: it bypasses RLS.
export const environment = {
  production: false,
  supabaseUrl: 'https://YOUR_PROJECT_REF.supabase.co',
  supabaseKey: 'YOUR_SUPABASE_PUBLISHABLE_ANON_KEY',
};
