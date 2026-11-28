-- HeartTalk core economy
-- 1 spent coin = ₹1 face value, split ₹0.50 Host / ₹0.50 HeartTalk.
-- Voice 1 coin per started minute; video 2 coins per started minute; chat free.
-- Host coin rewards are separate from spendable user wallet coins.

create or replace function public.hearttalk_end_call(target_call_id uuid,final_status text default 'ended')
returns jsonb language plpgsql security definer set search_path='' as $function$
declare
 v_actor uuid:=auth.uid(); v_call public.call_sessions%rowtype; v_host uuid; v_user uuid;
 v_seconds integer; v_rate integer; v_coins integer; v_host_share integer; v_platform_share integer; v_balance bigint;
begin
 if v_actor is null then raise exception 'Authentication required'; end if;
 if final_status not in ('rejected','ended','cancelled','busy') then raise exception 'Invalid final call status'; end if;
 select * into v_call from public.call_sessions where id=target_call_id and (caller_id=v_actor or callee_id=v_actor) for update;
 if not found then raise exception 'Call not found'; end if;
 if v_call.status not in ('ringing','accepted') then
  return jsonb_build_object('updated',false,'status',v_call.status,'charged_coins',v_call.charged_coins,'host_earned_coins',v_call.host_earned_coins,'billing_status',v_call.billing_status);
 end if;
 update public.call_sessions set status=final_status,ended_at=now() where id=target_call_id and status in ('ringing','accepted');
 if final_status<>'ended' or v_call.status<>'accepted' or v_call.started_at is null then
  return jsonb_build_object('updated',true,'status',final_status,'charged_coins',0,'billing_status','not_billable');
 end if;
 select h.user_id into v_host from public.hosts h
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
 v_host_share:=v_coins; v_platform_share:=v_coins;
 perform 1 from auth.users where id=v_user for update;
 select coalesce(sum(amount),0) into v_balance from public.wallet_ledger where user_id=v_user;
 if v_balance<v_coins then
  update public.call_sessions set billed_user_id=v_user,billed_host_id=v_host,billed_seconds=v_seconds,
   charged_coins=0,host_earned_coins=0,platform_earned_coins=0,billing_status='insufficient_coins'
  where id=target_call_id;
  return jsonb_build_object('updated',true,'status','ended','required_coins',v_coins,'charged_coins',0,'billing_status','insufficient_coins');
 end if;
 if v_coins>0 then
  insert into public.wallet_ledger(user_id,amount,entry_type,reference_id)
  values(v_user,-v_coins,'spend','call_session:'||target_call_id::text);
 end if;
 update public.call_sessions set billed_user_id=v_user,billed_host_id=v_host,billed_seconds=v_seconds,
  charged_coins=v_coins,host_earned_coins=v_host_share,platform_earned_coins=v_platform_share,
  billing_status=case when v_coins=0 then 'no_charge' else 'charged' end
 where id=target_call_id;
 insert into public.hearttalk_call_session_earnings(call_id,host_id,user_id,call_type,billed_seconds,charged_coins,earned_coins)
 values(target_call_id,v_host,v_user,v_call.call_type,v_seconds,v_coins,v_host_share)
 on conflict(call_id) do nothing;
 return jsonb_build_object('updated',true,'status','ended','billed_seconds',v_seconds,
  'charged_coins',v_coins,'host_earned_coins',v_host_share,'platform_earned_coins',v_platform_share,
  'host_earned_value_paise',v_host_share::bigint*50,'platform_earned_value_paise',v_platform_share::bigint*50,
  'billing_status',case when v_coins=0 then 'no_charge' else 'charged' end);
end;
$function$;

create or replace function public.hearttalk_send_gift(target_host_id uuid,selected_gift_code text,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare
 v_sender uuid:=auth.uid(); v_price integer; v_title text; v_emoji text; v_host_share integer; v_platform_share integer;
 v_host_share_paise bigint; v_platform_share_paise bigint; v_event uuid; v_balance bigint; v_result jsonb; v_sender_name text;
begin
 if v_sender is null then raise exception 'Authentication required'; end if;
 if p_request_id is null then raise exception 'Gift request ID is required'; end if;
 if target_host_id is null or target_host_id=v_sender then raise exception 'Choose another member'; end if;
 perform 1 from auth.users where id in (v_sender,target_host_id) order by id for update;
 select result into v_result from public.hearttalk_gift_requests where sender_id=v_sender and request_id=p_request_id;
 if v_result is not null then return v_result; end if;
 if exists(select 1 from public.blocked_users b where (b.blocker_id=v_sender and b.blocked_user_id=target_host_id) or (b.blocker_id=target_host_id and b.blocked_user_id=v_sender)) then
  raise exception 'You cannot send a gift because this conversation is blocked';
 end if;
 if not exists(select 1 from public.hosts h join public.host_applications a on a.user_id=h.user_id and a.status='approved'
  join public.host_kyc_documents d on d.user_id=h.user_id and d.document_type='video_selfie' and d.status='approved'
  where h.user_id=target_host_id and h.host_status='active') then raise exception 'Host is not approved'; end if;
 select coin_price,title,emoji into v_price,v_title,v_emoji from public.hearttalk_gift_catalog where gift_code=selected_gift_code and active=true;
 if v_price is null then raise exception 'Gift is unavailable'; end if;
 if v_price<1 then raise exception 'Gift price is invalid'; end if;
 select coalesce(sum(amount),0) into v_balance from public.wallet_ledger where user_id=v_sender;
 if v_balance<v_price then raise exception 'Not enough coins'; end if;
 v_host_share:=v_price; v_platform_share:=0;
 v_host_share_paise:=v_price::bigint*50; v_platform_share_paise:=v_price::bigint*50;
 insert into public.wallet_ledger(user_id,amount,entry_type,reference_id) values(v_sender,-v_price,'spend','gift:'||public.gen_random_uuid()::text);
 insert into public.hearttalk_gift_events(sender_id,host_id,gift_code,coin_price,host_share_coins,platform_share_coins,host_share_paise,platform_share_paise)
 values(v_sender,target_host_id,selected_gift_code,v_price,v_host_share,v_platform_share,v_host_share_paise,v_platform_share_paise)
 returning id into v_event;
 insert into public.hearttalk_host_earnings(host_id,gift_event_id,earned_coins) values(target_host_id,v_event,v_host_share);
 insert into public.hearttalk_host_cash_ledger(host_id,amount_paise,entry_type,reference_id,source_reference,note,created_by)
 values(target_host_id,v_host_share_paise,'earning_credit',v_event,'gift:'||v_event::text,'Gift earnings converted at ₹0.50 per Host reward coin',null)
 on conflict(host_id,source_reference) do nothing;
 select coalesce(nullif(trim(p.display_name),''),nullif(trim(p.username),''),'A HeartTalk member') into v_sender_name
 from public.profiles p where p.id=v_sender;
 if v_sender_name is null then v_sender_name:='A HeartTalk member'; end if;
 insert into public.messages(sender_id,receiver_id,message)
 values(v_sender,target_host_id,'[[GIFT]]'||jsonb_build_object('gift_event_id',v_event,'gift_code',selected_gift_code,'title',v_title,
  'emoji',v_emoji,'coin_price',v_price,'host_earned_coins',v_host_share,
  'host_earned_value_paise',v_host_share_paise,'platform_share_value_paise',v_platform_share_paise)::text);
 insert into public.notifications(user_id,kind,title,body,data)
 values(target_host_id,'gift_received','You received a gift!',v_sender_name||' sent you '||coalesce(v_emoji,'🎁')||' '||v_title||'.',
  jsonb_build_object('gift_event_id',v_event,'sender_id',v_sender,'sender_name',v_sender_name,'gift_code',selected_gift_code,
  'gift_title',v_title,'gift_emoji',v_emoji,'coin_price',v_price,'host_earned_coins',v_host_share,
  'host_earned_value_paise',v_host_share_paise,'platform_share_value_paise',v_platform_share_paise,'conversation_user_id',v_sender));
 v_result:=jsonb_build_object('gift_event_id',v_event,'gift_code',selected_gift_code,'gift_title',v_title,'gift_emoji',v_emoji,
  'coin_price',v_price,'host_earned_coins',v_host_share,'host_earned_value_paise',v_host_share_paise,
  'platform_share_coins',v_platform_share,'platform_share_value_paise',v_platform_share_paise,'status','delivered');
 insert into public.hearttalk_gift_requests(sender_id,request_id,result) values(v_sender,p_request_id,v_result);
 return v_result;
end;
$function$;
revoke all on function public.hearttalk_send_gift(uuid,text,uuid) from public,anon;
grant execute on function public.hearttalk_send_gift(uuid,text,uuid) to authenticated;

create or replace function public.hearttalk_get_host_earnings()
returns jsonb language plpgsql security definer set search_path='' as $function$
declare v_user uuid:=auth.uid(); v_total bigint; v_count bigint; v_gift_count bigint; v_recent jsonb; v_available_paise bigint;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 select
  coalesce((select sum(earned_coins) from public.hearttalk_host_earnings where host_id=v_user),0)
   +coalesce((select sum(earned_coins) from public.hearttalk_call_session_earnings where host_id=v_user),0),
  (select count(*) from public.hearttalk_host_earnings where host_id=v_user)
   +(select count(*) from public.hearttalk_call_session_earnings where host_id=v_user),
  (select count(*) from public.hearttalk_host_earnings where host_id=v_user)
 into v_total,v_count,v_gift_count;
 select coalesce(sum(amount_paise),0) into v_available_paise from public.hearttalk_host_cash_ledger where host_id=v_user;
 select coalesce(jsonb_agg(item order by sort_at desc),'[]'::jsonb) into v_recent
 from (
  select item,sort_at from (
   select jsonb_build_object('gift_event_id',e.gift_event_id,'earned_coins',e.earned_coins,'created_at',e.created_at,
    'gift_title',c.title,'emoji',c.emoji,'earned_value_paise',e.earned_coins::bigint*50) item,e.created_at sort_at
   from public.hearttalk_host_earnings e join public.hearttalk_gift_events g on g.id=e.gift_event_id
    join public.hearttalk_gift_catalog c on c.gift_code=g.gift_code where e.host_id=v_user
   union all
   select jsonb_build_object('gift_event_id',null,'call_id',e.call_id,'earned_coins',e.earned_coins,'created_at',e.created_at,
    'gift_title',case when e.call_type='voice' then 'Voice call earnings' else 'Video call earnings' end,
    'emoji','📞','earned_value_paise',e.earned_coins::bigint*50) item,e.created_at sort_at
   from public.hearttalk_call_session_earnings e where e.host_id=v_user
  ) history_rows
 ) q;
 return jsonb_build_object('earned_coins',v_total,'gift_count',v_gift_count,'earning_count',v_count,'history',v_recent,
  'available_amount_paise',v_available_paise,'host_coin_value_paise',50,'cash_withdrawal_enabled',true,'chat_billing_coins',0);
end;
$function$;
revoke all on function public.hearttalk_get_host_earnings() from public,anon;
grant execute on function public.hearttalk_get_host_earnings() to authenticated;

create or replace function public.admin_list_call_commission_logs(p_limit integer default 100)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare v_rows jsonb;
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc),'[]'::jsonb) into v_rows
 from (
  select 'call'::text as record_type,c.id::text as record_id,c.caller_id,c.callee_id,c.call_type,c.status,
   case when c.started_at is not null and c.ended_at is not null
    then greatest(0,extract(epoch from(c.ended_at-c.started_at))::integer) else null end as duration_seconds,
   c.charged_coins as total_coins,c.host_earned_coins as host_share_coins,c.platform_earned_coins as platform_share_coins,
   c.host_earned_coins::bigint*50 as host_share_paise,c.platform_earned_coins::bigint*50 as platform_share_paise,c.created_at
  from public.call_sessions c
  union all
  select 'gift_commission',g.id::text,g.sender_id,g.host_id,g.gift_code,'settled',null::integer,g.coin_price,
   g.host_share_coins,g.platform_share_coins,g.host_share_paise,g.platform_share_paise,g.created_at
  from public.hearttalk_gift_events g
  order by created_at desc limit greatest(1,least(coalesce(p_limit,100),500))
 ) q;
 return v_rows;
end;
$function$;
revoke all on function public.admin_list_call_commission_logs(integer) from public,anon;
grant execute on function public.admin_list_call_commission_logs(integer) to authenticated;

update public.hearttalk_gift_events
set host_share_coins=coin_price,platform_share_coins=0,
    host_share_paise=coin_price::bigint*50,platform_share_paise=coin_price::bigint*50
where id in ('1c9bf2da-f3bf-480a-b7f5-c0507216104b'::uuid,'f0b17f67-dd97-4a1c-9dd4-6319e6a859d0'::uuid);
update public.hearttalk_gift_requests gr
set result=gr.result||jsonb_build_object('host_earned_coins',e.coin_price,
 'host_earned_value_paise',e.coin_price::bigint*50,'platform_share_coins',0,
 'platform_share_value_paise',e.coin_price::bigint*50)
from public.hearttalk_gift_events e
where e.id in ('1c9bf2da-f3bf-480a-b7f5-c0507216104b'::uuid,'f0b17f67-dd97-4a1c-9dd4-6319e6a859d0'::uuid)
and gr.result->>'gift_event_id'=e.id::text;
