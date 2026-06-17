// TEMPLATE — committed to git. The real `environment.prod.ts` is gitignored.
// Used by the production build via angular.json `fileReplacements`.
// SECURITY: publishable / anon key ONLY. Never the service_role key.
export const environment = {
  production: true,
  supabaseUrl: 'https://YOUR_PROJECT_REF.supabase.co',
  supabaseKey: 'YOUR_SUPABASE_PUBLISHABLE_ANON_KEY',
};
