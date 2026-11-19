-- HeartTalk chat billing correction: 100% of newly charged chat coins go to Host.
-- Additive migration only: does not delete, rewrite, or backfill any existing data.
-- Gift billing is untouched. Existing completed chat sessions remain unchanged.

create or replace function public.hearttalk_end_chat_billing(p_session_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 v_user uuid:=auth.uid();
 v_s public.hearttalk_chat_sessions%rowtype;
 v_seconds integer;
 v_coins integer;
 v_host_share integer;
 v_balance bigint;
 v_bill_end timestamptz;
 v_earning_id bigint;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 select * into v_s from public.hearttalk_chat_sessions
 where id=p_session_id and user_id=v_user for update;
 if not found then raise exception 'Chat billing session not found'; end if;
 if v_s.status<>'active' then
  return jsonb_build_object('session_id',v_s.id,'elapsed_seconds',v_s.elapsed_seconds,
   'charged_coins',v_s.charged_coins,'host_earned_coins',v_s.host_earned_coins,'status',v_s.status);
 end if;

 -- Preserve heartbeat safety: bill only until last heartbeat plus 20 seconds.
 v_bill_end:=least(now(),coalesce(v_s.last_heartbeat_at,v_s.started_at)+interval '20 seconds');
 v_seconds:=greatest(0,extract(epoch from (v_bill_end-v_s.started_at))::integer);
 v_coins:=floor(v_seconds*4/300.0)::integer;
 -- Chat earnings: Host gets 100% of coins charged. No platform share.
 v_host_share:=v_coins;

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

 -- The unique session_id makes the earning record idempotent. Credit Host wallet
 -- only when this session's earning record is newly created, in the same transaction.
 insert into public.hearttalk_chat_session_earnings(session_id,host_id,earned_coins)
 values(p_session_id,v_s.host_id,v_host_share)
 on conflict(session_id) do nothing
 returning id into v_earning_id;

 if v_earning_id is not null and v_host_share>0 then
  perform 1 from auth.users where id=v_s.host_id for update;
  insert into public.wallet_ledger(user_id,amount,entry_type,reference_id)
  values(v_s.host_id,v_host_share,'admin_adjustment','chat_host_credit:'||p_session_id::text);
 end if;

 return jsonb_build_object('session_id',p_session_id,'elapsed_seconds',v_seconds,
  'charged_coins',v_coins,'host_earned_coins',v_host_share,
  'platform_share_coins',0,'status',case when v_coins=0 then 'no_charge' else 'charged' end);
end; $$;
revoke all on function public.hearttalk_end_chat_billing(uuid) from public;
grant execute on function public.hearttalk_end_chat_billing(uuid) to authenticated;

-- Host earnings summary: keep all gift history and append chat earnings.
create or replace function public.hearttalk_get_host_earnings()
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 v_user uuid:=auth.uid();
 v_total bigint;
 v_count bigint;
 v_recent jsonb;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 select coalesce((select sum(earned_coins) from public.hearttalk_host_earnings where host_id=v_user),0)
      +coalesce((select sum(earned_coins) from public.hearttalk_chat_session_earnings where host_id=v_user),0),
      (select count(*) from public.hearttalk_host_earnings where host_id=v_user)
      +(select count(*) from public.hearttalk_chat_session_earnings where host_id=v_user)
 into v_total,v_count;

 select coalesce(jsonb_agg(item),'[]'::jsonb) into v_recent from (
  select item from (
   select jsonb_build_object('gift_event_id',e.gift_event_id,'earned_coins',e.earned_coins,
    'created_at',e.created_at,'gift_title',c.title,'emoji',c.emoji) as item,e.created_at as sort_at
   from public.hearttalk_host_earnings e
   join public.hearttalk_gift_events g on g.id=e.gift_event_id
   join public.hearttalk_gift_catalog c on c.gift_code=g.gift_code
   where e.host_id=v_user
   union all
   select jsonb_build_object('gift_event_id',null,'earned_coins',ce.earned_coins,
    'created_at',ce.created_at,'gift_title','Chat earnings','emoji','💬') as item,ce.created_at as sort_at
   from public.hearttalk_chat_session_earnings ce where ce.host_id=v_user
  ) combined order by sort_at desc limit 50
 ) q;
 return jsonb_build_object('earned_coins',v_total,'gift_count',v_count,'history',v_recent,'cash_withdrawal_enabled',false);
end; $$;
revoke all on function public.hearttalk_get_host_earnings() from public;
grant execute on function public.hearttalk_get_host_earnings() to authenticated;
