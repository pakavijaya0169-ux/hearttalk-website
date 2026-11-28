-- Lock down the trigger function's search_path to prevent object shadowing.
-- The trigger remains attached to public.profiles and its function body only uses NEW and pg_catalog.now().
ALTER FUNCTION public.set_profile_updated_at() SET search_path = '';
