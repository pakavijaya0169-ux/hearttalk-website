-- Safe chat billing heartbeat lifecycle. Additive: preserves all existing rows and messages.
alter table public.hearttalk_chat_sessions
 add column if not exists last_heartbeat_at timestamptz not null default now();

create or replace function public.hearttalk_chat_billing_heartbeat(p_session_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid(); v_s public.hearttalk_chat_sessions%rowtype;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 update public.hearttalk_chat_sessions
 set last_heartbeat_at=now()
 where id=p_session_id and user_id=v_user and status='active'
 returning * into v_s;
 if not found then raise exception 'Active billing session not found'; end if;
 return jsonb_build_object('session_id',v_s.id,'last_heartbeat_at',v_s.last_heartbeat_at);
end; $$;
revoke all on function public.hearttalk_chat_billing_heartbeat(uuid) from public;
grant execute on function public.hearttalk_chat_billing_heartbeat(uuid) to authenticated;

create or replace function public.hearttalk_end_chat_billing(p_session_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 v_user uuid:=auth.uid(); v_s public.hearttalk_chat_sessions%rowtype;
 v_seconds integer; v_coins integer; v_host_share integer; v_balance bigint; v_bill_end timestamptz;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 select * into v_s from public.hearttalk_chat_sessions
 where id=p_session_id and user_id=v_user for update;
 if not found then raise exception 'Chat billing session not found'; end if;
 if v_s.status<>'active' then
  return jsonb_build_object('session_id',v_s.id,'elapsed_seconds',v_s.elapsed_seconds,
   'charged_coins',v_s.charged_coins,'host_earned_coins',v_s.host_earned_coins,'status',v_s.status);
 end if;
 -- If the browser disappears, bill only through the last heartbeat plus a 20-second grace cap.
 v_bill_end:=least(now(),coalesce(v_s.last_heartbeat_at,v_s.started_at)+interval '20 seconds');
 v_seconds:=greatest(0,extract(epoch from (v_bill_end-v_s.started_at))::integer);
 v_coins:=floor(v_seconds*4/300.0)::integer;
 v_host_share:=floor(v_coins*0.50)::integer;
 perform 1 from auth.users where id=v_user for update;
 select coalesce(sum(amount),0) into v_balance from public.wallet_ledger where user_id=v_user;
 if v_balance<v_coins then
  update public.hearttalk_chat_sessions set ended_at=v_bill_end,elapsed_seconds=v_seconds,
   charged_coins=0,host_earned_coins=0,status='no_charge' where id=p_session_id;
  return jsonb_build_object('session_id',p_session_id,'elapsed_seconds',v_seconds,
   'required_coins',v_coins,'charged_coins',0,'host_earned_coins',0,'status','insufficient_coins');
 end if;
 if v_coins>0 then
  insert into public.wallet_ledger(user_id,amount,entry_type,reference_id)
  values(v_user,-v_coins,'spend','chat_session:'||p_session_id::text);
 end if;
 update public.hearttalk_chat_sessions set ended_at=v_bill_end,elapsed_seconds=v_seconds,
  charged_coins=v_coins,host_earned_coins=v_host_share,
  status=case when v_coins=0 then 'no_charge' else 'ended' end
 where id=p_session_id;
 insert into public.hearttalk_chat_session_earnings(session_id,host_id,earned_coins)
 values(p_session_id,v_s.host_id,v_host_share) on conflict(session_id) do nothing;
 return jsonb_build_object('session_id',p_session_id,'elapsed_seconds',v_seconds,
  'charged_coins',v_coins,'host_earned_coins',v_host_share,'status',case when v_coins=0 then 'no_charge' else 'charged' end);
end; $$;
revoke all on function public.hearttalk_end_chat_billing(uuid) from public;
grant execute on function public.hearttalk_end_chat_billing(uuid) to authenticated;
