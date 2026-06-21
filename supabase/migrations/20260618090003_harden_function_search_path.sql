-- Hardening: pin search_path on the auth-seam helper functions.
-- These STABLE functions back every RLS policy and run inside SECURITY DEFINER
-- RPCs, so a role-mutable search_path is a real privilege-escalation seam
-- (Supabase linter 0011_function_search_path_mutable). They reference only
-- fully-qualified app.* functions and pg_catalog built-ins, so an EMPTY
-- search_path is safe (pg_catalog is always searched implicitly).
-- Forward-only: the originals were already applied (local + cloud); this ALTER
-- pins them in place without rewriting the immutable creating migration.

alter function app.current_claims()    set search_path = '';
alter function app.current_branch_id() set search_path = '';
alter function app.is_admin()          set search_path = '';
alter function app.current_user_id()   set search_path = '';
