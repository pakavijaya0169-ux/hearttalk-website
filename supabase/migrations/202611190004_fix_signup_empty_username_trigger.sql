-- Fix signup profile creation: ensure new profiles receive a unique non-empty username.
-- Replaces only the trigger function; existing users and rows are not modified.
CREATE OR REPLACE FUNCTION public.handle_new_hearttalk_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  INSERT INTO public.profiles (id, display_name, username)
  VALUES (
    new.id,
    COALESCE(new.raw_user_meta_data ->> 'display_name', ''),
    'ht_' || replace(new.id::text, '-', '')
  )
  ON CONFLICT (id) DO NOTHING;

  RETURN new;
END;
$function$;
