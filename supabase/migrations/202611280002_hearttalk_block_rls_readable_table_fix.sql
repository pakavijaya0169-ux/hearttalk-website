-- Keep RLS expressions on the authenticated-readable block table.
-- user_blocks remains in sync and the SECURITY DEFINER call RPC checks it.

drop policy if exists "Users can send messages unless blocked" on public.messages;
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

drop policy if exists "Caller can create call unless blocked" on public.call_sessions;
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
