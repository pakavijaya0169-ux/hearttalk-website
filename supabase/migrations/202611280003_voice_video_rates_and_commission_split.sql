-- HeartTalk call billing:
-- Voice: 1 User Wallet Coin/min (₹1 value).
-- Video: 2 User Wallet Coins/min (₹2 value).
-- Host receives ₹0.50 for every billed User Wallet Coin.
-- HeartTalk retains the other ₹0.50.
-- Each Host Reward Coin is worth ₹0.50.

create or replace function public.hearttalk_end_call(target_call_id uuid, final_status text default 'ended')
returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
 v_actor uuid:=auth.uid();
 v_call public.call_sessions%rowtype;
 v_host uuid;
 v_user uuid;
 v_seconds integer;
 v_rate integer;
 v_coins integer;
 v_host_share integer;
 v_platform_share integer;
 v_balance bigint;
begin
 if v_actor is null then raise exception 'Authentication required'; end if;
 if final_status not in ('rejected','ended','cancelled','busy') then raise exception 'Invalid final call status'; end if;
 select * into v_call from public.call_sessions
 where id=target_call_id and (caller_id=v_actor or callee_id=v_actor) for update;
 if not found then raise exception 'Call not found'; end if;
 if v_call.status not in ('ringing','accepted') then
  return jsonb_build_object('updated',false,'status',v_call.status,'charged_coins',v_call.charged_coins,'host_earned_coins',v_call.host_earned_coins,'billing_status',v_call.billing_status);
 end if;
 update public.call_sessions set status=final_status,ended_at=now()
 where id=target_call_id and status in ('ringing','accepted');
 if final_status<>'ended' or v_call.status<>'accepted' or v_call.started_at is null then
  return jsonb_build_object('updated',true,'status',final_status,'charged_coins',0,'billing_status','not_billable');
 end if;
 select h.user_id into v_host
 from public.hosts h
 join public.host_applications a on a.user_id=h.user_id and a.status='approved'
 join public.host_kyc_documents d on d.user_id=h.user_id and d.document_type='video_selfie' and d.status='approved'
 where h.host_status='active' and h.user_id in (v_call.caller_id,v_call.callee_id) limit 1;
 if v_host is null then
  update public.call_sessions set billing_status='not_billable' where id=target_call_id;
  return jsonb_build_object('updated',true,'status','ended','charged_coins',0,'billing_status','not_billable');
 end if;
 v_user:=case when v_call.caller_id=v_host then v_call.callee_id else v_call.caller_id end;
 if not exists(select 1 from public.profiles p where p.id=v_user and lower(coalesce(p.gender,''))='male') then
  update public.call_sessions set billing_status='not_billable' where id=target_call_id;
  return jsonb_build_object('updated',true,'status','ended','charged_coins',0,'billing_status','not_billable');
 end if;
 v_seconds:=greatest(0,extract(epoch from(now()-v_call.started_at))::integer);
 v_rate:=case when v_call.call_type='voice' then 1 else 2 end;
 v_coins:=case when v_seconds=0 then 0 else ceil(v_seconds/60.0)::integer*v_rate end;
 -- Host Reward Coin and HeartTalk share are each separate ₹0.50 value units.
 v_host_share:=v_coins;
 v_platform_share:=v_coins;
 perform 1 from auth.users where id=v_user for update;
 select coalesce(sum(amount),0) into v_balance from public.wallet_ledger where user_id=v_user;
 if v_balance<v_coins then
  update public.call_sessions
  set billed_user_id=v_user,billed_host_id=v_host,billed_seconds=v_seconds,
      charged_coins=0,host_earned_coins=0,platform_earned_coins=0,billing_status='insufficient_coins'
  where id=target_call_id;
  return jsonb_build_object('updated',true,'status','ended','required_coins',v_coins,'charged_coins',0,'billing_status','insufficient_coins');
 end if;
 if v_coins>0 then
  insert into public.wallet_ledger(user_id,amount,entry_type,reference_id)
  values(v_user,-v_coins,'spend','call_session:'||target_call_id::text);
 end if;
 update public.call_sessions
 set billed_user_id=v_user,billed_host_id=v_host,billed_seconds=v_seconds,
     charged_coins=v_coins,host_earned_coins=v_host_share,platform_earned_coins=v_platform_share,
     billing_status=case when v_coins=0 then 'no_charge' else 'charged' end
 where id=target_call_id;
 insert into public.hearttalk_call_session_earnings(
  call_id,host_id,user_id,call_type,billed_seconds,charged_coins,earned_coins
 ) values(target_call_id,v_host,v_user,v_call.call_type,v_seconds,v_coins,v_host_share)
 on conflict(call_id) do nothing;
 return jsonb_build_object(
  'updated',true,'status','ended','billed_seconds',v_seconds,
  'charged_coins',v_coins,'host_earned_coins',v_host_share,
  'host_earned_value_paise',v_host_share::bigint*50,
  'platform_earned_coins',v_platform_share,
  'platform_earned_value_paise',v_platform_share::bigint*50,
  'billing_status',case when v_coins=0 then 'no_charge' else 'charged' end
 );
end;
$function$;
revoke all on function public.hearttalk_end_call(uuid,text) from public,anon;
grant execute on function public.hearttalk_end_call(uuid,text) to authenticated;

create or replace function public.admin_list_call_commission_logs(p_limit integer default 100)
returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare v_rows jsonb;
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc),'[]'::jsonb) into v_rows
 from (
  select 'call'::text as record_type,c.id::text as record_id,c.caller_id,c.callee_id,
   c.call_type,c.status,
   case when c.started_at is not null and c.ended_at is not null
    then greatest(0,extract(epoch from(c.ended_at-c.started_at))::integer) else null end as duration_seconds,
   c.charged_coins as total_coins,c.host_earned_coins as host_share_coins,
   c.platform_earned_coins as platform_share_coins,c.created_at
  from public.call_sessions c
  union all
  select 'gift_commission',g.id::text,g.sender_id,g.host_id,g.gift_code,'settled',
   null::integer,g.coin_price,g.host_share_coins,g.platform_share_coins,g.created_at
  from public.hearttalk_gift_events g
  order by created_at desc limit greatest(1,least(coalesce(p_limit,100),500))
 ) q;
 return v_rows;
end;
$function$;
revoke all on function public.admin_list_call_commission_logs(integer) from public,anon;
grant execute on function public.admin_list_call_commission_logs(integer) to authenticated;
