-- HeartTalk contact-sharing safety guard (India)
-- Blocks Indian mobile numbers in direct messages and ends an active/ringing call
-- between the same two members. No phone number content is stored in the audit log.

create table if not exists public.contact_safety_events (
  id bigint generated always as identity primary key,
  actor_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  ended_call_count integer not null default 0,
  reason text not null default 'phone_number_shared_in_chat',
  created_at timestamptz not null default now()
);

alter table public.contact_safety_events enable row level security;

drop policy if exists "Admins can read contact safety events"
  on public.contact_safety_events;
create policy "Admins can read contact safety events"
  on public.contact_safety_events
  for select to authenticated
  using (public.is_hearttalk_admin());

grant select on public.contact_safety_events to authenticated;

create or replace function public.hearttalk_block_phone_sharing()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ended_count integer := 0;
begin
  if new.message is null then
    return new;
  end if;

  -- Indian mobile numbers: 10 digits, optionally +91/91/0 prefix,
  -- with spaces, dots, brackets or hyphens between digits.
  if new.message !~* '(^|[^0-9])(\+?91[[:space:]-]*)?0?[6-9]([[:space:]().-]*[0-9]){9}([^0-9]|$)' then
    return new;
  end if;

  update public.call_sessions
     set status = 'ended',
         ended_at = now()
   where (
      (caller_id = new.sender_id and callee_id = new.receiver_id)
      or
      (caller_id = new.receiver_id and callee_id = new.sender_id)
   )
     and status in ('ringing', 'accepted');

  get diagnostics v_ended_count = row_count;

  insert into public.contact_safety_events
    (actor_id, recipient_id, ended_call_count, reason)
  values
    (new.sender_id, new.receiver_id, v_ended_count,
     'phone_number_shared_in_chat');

  -- Do not retain or display the actual number.
  new.message := '[[SAFETY_BLOCKED_PHONE]]';
  return new;
end;
$$;

drop trigger if exists hearttalk_block_phone_sharing
  on public.messages;
create trigger hearttalk_block_phone_sharing
before insert on public.messages
for each row
execute function public.hearttalk_block_phone_sharing();
