-- HeartTalk scheduled push cron (run only after the Edge Function is deployed and
-- the SCHEDULED_PUSH_SECRET is stored in Supabase Vault).
-- Before applying this migration, create the Vault secret:
-- select vault.create_secret('<YOUR_RANDOM_SECRET>', 'SCHEDULED_PUSH_SECRET');
-- Use the exact same secret as the Edge Function secret SCHEDULED_PUSH_SECRET.
-- Do not commit the real secret to source control.

create extension if not exists pg_cron with schema extensions;
create extension if not exists pg_net with schema extensions;

do $$
begin
  if not exists (select 1 from vault.decrypted_secrets where name='SCHEDULED_PUSH_SECRET') then
    raise exception 'Create SCHEDULED_PUSH_SECRET in Supabase Vault before running this migration';
  end if;
end $$;

select cron.unschedule(jobid)
from cron.job
where jobname = 'hearttalk-dispatch-scheduled-push';

select cron.schedule(
  'hearttalk-dispatch-scheduled-push',
  '* * * * *',
  $job$
    select net.http_post(
      url := 'https://dognojmymhlaewrjqswz.supabase.co/functions/v1/dispatch-scheduled-push',
      headers := jsonb_build_object(
        'Content-Type','application/json',
        'Authorization','Bearer '||(select decrypted_secret from vault.decrypted_secrets where name='SCHEDULED_PUSH_SECRET')
      ),
      body := '{}'::jsonb
    );
  $job$
);
