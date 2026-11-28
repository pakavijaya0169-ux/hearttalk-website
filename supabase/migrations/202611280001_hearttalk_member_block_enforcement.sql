-- HeartTalk member block enforcement and synchronization.
-- Keep the legacy UI table and call-engine table in sync, and enforce blocks at the database boundary.

insert into public.user_blocks(blocker_id,blocked_id,created_at)
select blocker_id,blocked_user_id,created_at
from public.blocked_users
on conflict (blocker_id,blocked_id) do nothing;

insert into public.blocked_users(blocker_id,blocked_user_id,created_at)
select blocker_id,blocked_id,created_at
from public.user_blocks
on conflict (blocker_id,blocked_user_id) do nothing;

create or replace function public.hearttalk_sync_blocked_users_to_user_blocks()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
 if pg_trigger_depth()>1 then
  if tg_op='DELETE' then return old; end if;
  return new;
 end if;
 if tg_op='INSERT' then
  insert into public.user_blocks(blocker_id,blocked_id,created_at)
  values(new.blocker_id,new.blocked_user_id,new.created_at)
  on conflict (blocker_id,blocked_id) do nothing;
  return new;
 end if;
 if tg_op='DELETE' then
  delete from public.user_blocks where blocker_id=old.blocker_id and blocked_id=old.blocked_user_id;
  return old;
 end if;
 return new;
end;
$$;

create or replace function public.hearttalk_sync_user_blocks_to_blocked_users()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
 if pg_trigger_depth()>1 then
  if tg_op='DELETE' then return old; end if;
  return new;
 end if;
 if tg_op='INSERT' then
  insert into public.blocked_users(blocker_id,blocked_user_id,created_at)
  values(new.blocker_id,new.blocked_id,new.created_at)
  on conflict (blocker_id,blocked_user_id) do nothing;
  return new;
 end if;
 if tg_op='DELETE' then
  delete from public.blocked_users where blocker_id=old.blocker_id and blocked_user_id=old.blocked_id;
  return old;
 end if;
 return new;
end;
$$;

drop trigger if exists hearttalk_sync_blocked_users_to_user_blocks on public.blocked_users;
create trigger hearttalk_sync_blocked_users_to_user_blocks
after insert or delete on public.blocked_users
for each row execute function public.hearttalk_sync_blocked_users_to_user_blocks();

drop trigger if exists hearttalk_sync_user_blocks_to_blocked_users on public.user_blocks;
create trigger hearttalk_sync_user_blocks_to_blocked_users
after insert or delete on public.user_blocks
for each row execute function public.hearttalk_sync_user_blocks_to_blocked_users();

create or replace function public.hearttalk_block_member(p_blocked_user_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_user uuid:=auth.uid(); v_ended_calls integer:=0;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 if p_blocked_user_id is null or p_blocked_user_id=v_user then raise exception 'Choose another HeartTalk member'; end if;
 perform 1 from auth.users where id in (v_user,p_blocked_user_id) order by id for update;
 insert into public.blocked_users(blocker_id,blocked_user_id)
 values(v_user,p_blocked_user_id)
 on conflict (blocker_id,blocked_user_id) do nothing;
 update public.call_sessions
 set status='ended',ended_at=coalesce(ended_at,now())
 where status in ('ringing','accepted')
 and ((caller_id=v_user and callee_id=p_blocked_user_id) or (caller_id=p_blocked_user_id and callee_id=v_user));
 get diagnostics v_ended_calls=row_count;
 return jsonb_build_object('blocked',true,'ended_calls',v_ended_calls);
end;
$$;

create or replace function public.hearttalk_unblock_member(p_blocked_user_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_user uuid:=auth.uid(); v_deleted integer:=0;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 if p_blocked_user_id is null or p_blocked_user_id=v_user then raise exception 'Choose another HeartTalk member'; end if;
 perform 1 from auth.users where id in (v_user,p_blocked_user_id) order by id for update;
 delete from public.blocked_users where blocker_id=v_user and blocked_user_id=p_blocked_user_id;
 get diagnostics v_deleted=row_count;
 return jsonb_build_object('unblocked',true,'removed',v_deleted);
end;
$$;

revoke all on function public.hearttalk_sync_blocked_users_to_user_blocks() from public,anon,authenticated;
revoke all on function public.hearttalk_sync_user_blocks_to_blocked_users() from public,anon,authenticated;
revoke all on function public.hearttalk_block_member(uuid) from public,anon;
revoke all on function public.hearttalk_unblock_member(uuid) from public,anon;
grant execute on function public.hearttalk_block_member(uuid) to authenticated;
grant execute on function public.hearttalk_unblock_member(uuid) to authenticated;

drop policy if exists "Users can send messages" on public.messages;
drop policy if exists "Users can send messages as themselves" on public.messages;
create policy "Users can send messages unless blocked"
on public.messages for insert to authenticated
with check (
 auth.uid()=sender_id and sender_id<>receiver_id
 and not exists (
  select 1 from public.blocked_users b
  where (b.blocker_id=sender_id and b.blocked_user_id=receiver_id)
     or (b.blocker_id=receiver_id and b.blocked_user_id=sender_id)
 )
);

drop policy if exists "Caller can create call" on public.call_sessions;
create policy "Caller can create call unless blocked"
on public.call_sessions for insert to authenticated
with check (
 auth.uid()=caller_id and caller_id<>callee_id
 and not exists (
  select 1 from public.blocked_users b
  where (b.blocker_id=caller_id and b.blocked_user_id=callee_id)
     or (b.blocker_id=callee_id and b.blocked_user_id=caller_id)
 )
);
